classdef ECGRriArtifactRejectionService < handle
    properties (Access=private)
        sourceECG
        rriRaw
        peaksRawIdx
        peaksReviewedIdx
        rri

        lowLimitRRI
        highLimitRRI
        fs
        computeRriFromPeaksFcn

        artifactLogManager
        rriStateManager
        manualEditLog
        manualQC
        manualFigures
        manualReviewLog
        manualFlaggedWindows
    end

    methods
        function obj = ECGRriArtifactRejectionService()
            obj.artifactLogManager = ECGArtifactLogManager();
            obj.rriStateManager = ECGRriReviewStateManager();
            obj.resetState();
        end

        function result = run(obj, inputState, opts)
            if nargin < 2 || isempty(inputState)
                inputState = struct();
            end
            if nargin < 3 || isempty(opts)
                opts = struct();
            end
            opts = ECGRriArtifactRejectionService.applyRunDefaults(opts);

            obj.resetState();
            obj.loadInputState(inputState);
            obj.ensureArtifactLogManager();
            obj.ensureRriStateManager();
            obj.artifactLogManager.resetAutoLogs();

            method = ECGRriArtifactRejectionService.normalizeArtifactRejectionMethod(opts.ecgArtifactRejectionMethod);
            if any(method == ["trim","drop","manual","semiauto","semiautomatic"])
                obj.hydrateAutoArtifactState(opts);
            end

            switch method
                case "trim"
                    obj.rri = obj.capRRIValues(obj.rri, opts.verbose);
                    obj.saveReviewLogs(struct("saveDir", opts.ecgQCSaveDir));
                case "manual"
                    obj.runManualInspection(struct("saveDir", opts.ecgQCSaveDir, ...
                        "resumeIfExists", opts.resumeIfExists));
                case {"semiauto","semiautomatic"}
                    [rriPeaksIdx, rriInvalidIdx] = obj.getAutoRriMaskForManual();
                    manualOpts = struct("saveDir", opts.ecgQCSaveDir, ...
                        "resumeIfExists", opts.resumeIfExists, ...
                        "rriPeaksIdxInit", rriPeaksIdx, ...
                        "rriInvalidIdxInit", rriInvalidIdx);
                    obj.runManualInspection(manualOpts);
                case "drop"
                    obj.rri = obj.removeRriOutOfRange(obj.rri);
                    obj.saveReviewLogs(struct("saveDir", opts.ecgQCSaveDir));
                case "skip"
                    % Explicit no-op mode: keep detected RRI as-is.
                otherwise
                    warning('Rejection method not recognized');
            end

            result = struct();
            result.rri = obj.rri;
            result.rriRaw = obj.rriRaw;
            result.peaksRawIdx = obj.peaksRawIdx;
            result.peaksReviewedIdx = obj.peaksReviewedIdx;
        end
    end

    methods (Access=private)
        function resetState(obj)
            obj.sourceECG = [];
            obj.rriRaw = table();
            obj.peaksRawIdx = zeros(0,1);
            obj.peaksReviewedIdx = zeros(0,1);
            obj.rri = table();
            obj.lowLimitRRI = nan;
            obj.highLimitRRI = nan;
            obj.fs = [];
            obj.computeRriFromPeaksFcn = [];

            obj.manualEditLog = table();
            obj.manualQC = struct();
            obj.manualFigures = struct();
            obj.manualReviewLog = table();
            obj.manualFlaggedWindows = [];
        end

        function loadInputState(obj, inputState)
            if ~isstruct(inputState)
                return
            end

            if isfield(inputState, 'sourceECG')
                obj.sourceECG = inputState.sourceECG;
            end
            if isfield(inputState, 'rriRaw')
                obj.rriRaw = inputState.rriRaw;
            end
            if isfield(inputState, 'peaksRawIdx')
                obj.peaksRawIdx = inputState.peaksRawIdx;
            end
            if isfield(inputState, 'peaksReviewedIdx')
                obj.peaksReviewedIdx = inputState.peaksReviewedIdx;
            end
            if isfield(inputState, 'rri')
                obj.rri = inputState.rri;
            end
            if isempty(obj.rriRaw) && ~isempty(obj.rri)
                obj.rriRaw = obj.rri;
            end

            if isfield(inputState, 'lowLimitRRI')
                obj.lowLimitRRI = double(inputState.lowLimitRRI);
            end
            if isfield(inputState, 'highLimitRRI')
                obj.highLimitRRI = double(inputState.highLimitRRI);
            end
            if isfield(inputState, 'fs')
                obj.fs = double(inputState.fs);
            end
            if isfield(inputState, 'computeRriFromPeaksFcn') && isa(inputState.computeRriFromPeaksFcn, 'function_handle')
                obj.computeRriFromPeaksFcn = inputState.computeRriFromPeaksFcn;
            end
        end

        function rriData = capRRIValues(obj, rriData, verbose)
            if nargin < 3
                verbose = true;
            end
            %#ok<NASGU>
            obj.ensureArtifactLogManager();
            obj.ensureRriStateManager();

            lowerLimitMask = rriData.RRI < obj.lowLimitRRI;
            highLimitMask = rriData.RRI >= obj.highLimitRRI;

            [userId, sessionId] = obj.artifactLogManager.createAutoReviewIdentity("trim");
            rriCount = height(rriData);
            nSamples = obj.getCurrentSampleCount();
            fallbackPeaks = obj.getInitialPeaksForManualReview();
            sampleIdx = obj.rriStateManager.getRriSampleIdxForCurrentState(rriCount, true, ...
                obj.peaksRawIdx, obj.peaksReviewedIdx, fallbackPeaks, nSamples, obj.rri);
            lowerSampleIdx = sampleIdx(lowerLimitMask);
            highSampleIdx = sampleIdx(highLimitMask);

            obj.artifactLogManager.appendAutoRriEdits(lowerSampleIdx, ...
                "cap", "auto_trim_low_limit", userId, sessionId, ...
                obj.getPeakTimesForSampleIdx(lowerSampleIdx), obj.fs);
            obj.artifactLogManager.appendAutoRriEdits(highSampleIdx, ...
                "cap", "auto_trim_high_limit", userId, sessionId, ...
                obj.getPeakTimesForSampleIdx(highSampleIdx), obj.fs);

            rriData.RRI(lowerLimitMask) = obj.lowLimitRRI;
            rriData.RRI(highLimitMask) = obj.highLimitRRI;
            obj.rriStateManager.setReviewedRri(rriData);
        end

        function runManualInspection(obj, opts)
            if nargin < 2 || isempty(opts)
                opts = struct();
            end
            opts = ECGRriArtifactRejectionService.applyManualInspectionDefaults(opts);
            obj.ensureRriStateManager();

            if isempty(obj.sourceECG) || isempty(obj.fs)
                error('ECG:ManualInspectionMissingData', 'ECG data and fs must be available on the object.');
            end

            ECGRriArtifactRejectionService.ensureManualReviewPath();

            qcDir = ECGRriArtifactRejectionService.getManualInspectionQcDir(opts);
            resumeData = struct();
            resumeAvailable = false;
            trimCapSampleIdx = zeros(0,1);
            trimCapValuesMs = zeros(0,1);
            nSamples = obj.getCurrentSampleCount();
            if opts.resumeIfExists && strlength(qcDir) > 0 && exist(qcDir, 'dir')
                [resumeAvailable, resumeData] = ECGRriReviewStateManager.loadResumeState( ...
                    qcDir, nSamples, obj.peaksRawIdx);
            end

            if resumeAvailable
                if ~isempty(opts.rriPeaksIdxInit)
                    resumeData.rriPeaksIdx = opts.rriPeaksIdxInit(:);
                end
                if ~isempty(opts.rriInvalidIdxInit)
                    resumeData.rriInvalidIdx = unique([resumeData.rriInvalidIdx(:); opts.rriInvalidIdxInit(:)], 'stable');
                end
                [trimCapSampleIdx, trimCapValuesMs] = obj.extractTrimCapsFromEditLogs(resumeData.editLogs);
                peaksInit = resumeData.peaksReviewedIdx;
            elseif ~isempty(opts.rriPeaksIdxInit)
                peaksInit = opts.rriPeaksIdxInit(:);
            else
                peaksInit = obj.getInitialPeaksForManualReview();
            end
            if isempty(peaksInit)
                peaksInit = obj.getInitialPeaksForManualReview();
            end

            optsReview = opts;
            optsReview.launchUI = opts.launchUI;
            optsReview.userId = opts.userId;
            optsReview.sessionId = opts.sessionId;
            optsReview.returnFigures = opts.returnFigures;
            optsReview.verbose = opts.verbose;
            optsReview.computeIfEmpty = false;
            optsReview.ecgTimestamps = obj.getSourceEcgTimestamps();
            optsReview.rriCapSampleIdxInit = trimCapSampleIdx;
            optsReview.rriCapValuesMsInit = trimCapValuesMs;
            if resumeAvailable
                optsReview.resume = true;
                optsReview.peaksRawIdxOverride = resumeData.peaksRawIdx;
                optsReview.peaksReviewedIdxInit = resumeData.peaksReviewedIdx;
                optsReview.editLogsInit = resumeData.editLogs;
                optsReview.reviewLogInit = resumeData.reviewLog;
                optsReview.flaggedWindows = resumeData.flaggedWindows;
                optsReview.rriPeaksIdxInit = resumeData.rriPeaksIdx;
                optsReview.rriInvalidIdxInit = resumeData.rriInvalidIdx;
            end

            inspector = ECGManualInspector(obj.sourceECG.ECG, obj.fs, peaksInit, optsReview);
            inspector.run();
            if inspector.wasCancelled()
                return
            end
            [peaksReviewed, editLog, qc, figHandles] = inspector.exportResults();
            [rriPeaksIdx, rriInvalidIdx] = inspector.exportRriEdits();

            if isempty(obj.peaksRawIdx)
                obj.peaksRawIdx = peaksInit(:);
            end

            obj.peaksReviewedIdx = peaksReviewed(:);
            obj.manualEditLog = editLog;
            obj.manualQC = qc;
            if opts.returnFigures
                obj.manualFigures = figHandles;
            end
            obj.manualReviewLog = inspector.reviewLog;
            obj.manualFlaggedWindows = inspector.flaggedWindows;

            if isempty(obj.rriRaw) && ~isempty(obj.rri)
                obj.rriRaw = obj.rri;
            end

            fallbackPeaks = obj.getInitialPeaksForManualReview();
            obj.rri = obj.rriStateManager.applyManualReviewResult( ...
                rriPeaksIdx, rriInvalidIdx, obj.peaksReviewedIdx, obj.peaksRawIdx, ...
                fallbackPeaks, nSamples, obj.rri, @(x)obj.computeRriFromPeaks(x));
            obj.rri = obj.applyTrimCapsToRri(obj.rri, trimCapSampleIdx, trimCapValuesMs);

            if opts.saveQCArtifacts
                obj.saveManualInspectionQc(opts);
            end
        end

        function saveReviewLogs(obj, opts)
            qcDir = ECGRriArtifactRejectionService.getManualInspectionQcDir(opts);
            obj.saveReviewLogsAt(qcDir);
        end

        function saveReviewLogsAt(obj, qcDir)
            if strlength(qcDir) == 0
                return
            end
            obj.ensureArtifactLogManager();
            obj.artifactLogManager.saveReviewLogsAt(qcDir, obj.manualEditLog);
        end

        function peaksInit = getInitialPeaksForManualReview(obj)
            if ~isempty(obj.peaksRawIdx)
                peaksInit = obj.peaksRawIdx(:);
                return
            end

            peaksInit = [];
            rriTable = obj.rriRaw;
            if isempty(rriTable)
                rriTable = obj.rri;
            end
            if isempty(rriTable) || ~istable(rriTable)
                return
            end

            if ~ismember('Timestamp', rriTable.Properties.VariableNames) || ...
                    ~ismember('RRI', rriTable.Properties.VariableNames)
                return
            end

            tPeaks = rriTable.Timestamp;
            if isduration(tPeaks)
                tPeaks = seconds(tPeaks);
            end
            tPeaks = double(tPeaks(:));
            if isempty(obj.fs) || ~isfinite(obj.fs) || obj.fs <= 0
                return
            end
            peaksIdx = round(tPeaks * obj.fs) + 1;

            firstPeak = [];
            if ~isempty(tPeaks)
                firstTime = tPeaks(1) - (rriTable.RRI(1) / 1000);
                if isfinite(firstTime) && firstTime > 0
                    firstPeak = round(firstTime * obj.fs) + 1;
                end
            end
            peaksIdx = [firstPeak; peaksIdx]; %#ok<AGROW>

            nSamples = obj.getCurrentSampleCount();
            if ~isempty(nSamples) && isfinite(nSamples) && nSamples > 0
                peaksIdx = peaksIdx(peaksIdx >= 1 & peaksIdx <= nSamples);
            else
                peaksIdx = peaksIdx(peaksIdx >= 1);
            end
            peaksInit = unique(peaksIdx);
        end

        function rriData = computeRriFromPeaks(obj, peaksIdx)
            if ~isempty(obj.computeRriFromPeaksFcn)
                rriData = obj.computeRriFromPeaksFcn(peaksIdx);
                return
            end

            if isempty(peaksIdx)
                timestamps = obj.getSourceEcgTimestamps();
                if isempty(timestamps)
                    emptyTimestamp = [];
                else
                    emptyTimestamp = timestamps([]);
                end
                rriData = table(emptyTimestamp, zeros(0,1), 'VariableNames', {'Timestamp','RRI'});
                return
            end

            timestamps = obj.getSourceEcgTimestamps();
            if isempty(timestamps)
                nSamples = max(peaksIdx);
                timestamps = ECGRriArtifactRejectionService.getTimeVector(nSamples, obj.fs)';
            end

            rriData = ECGRriArtifactRejectionService.getRRITableFromPeakLocations(timestamps, peaksIdx);
        end

        function [rriPeaksIdx, rriInvalidIdx] = getAutoRriMaskForManual(obj)
            obj.ensureArtifactLogManager();
            obj.ensureRriStateManager();
            rriTable = obj.rri;
            useReviewedState = true;
            if isempty(rriTable)
                rriTable = obj.rriRaw;
                useReviewedState = false;
            end
            if isempty(rriTable) || ~istable(rriTable)
                rriPeaksIdx = zeros(0,1);
                rriInvalidIdx = zeros(0,1);
                return
            end
            if ~ismember('RRI', rriTable.Properties.VariableNames)
                rriPeaksIdx = zeros(0,1);
                rriInvalidIdx = zeros(0,1);
                return
            end

            nSamples = obj.getCurrentSampleCount();
            fallbackPeaks = obj.getInitialPeaksForManualReview();
            [rriPeaksIdx, rriInvalidIdxBase] = obj.rriStateManager.getIndicesForCurrentState( ...
                useReviewedState, obj.peaksRawIdx, obj.peaksReviewedIdx, ...
                fallbackPeaks, nSamples, obj.rri);

            if isempty(rriPeaksIdx)
                rriInvalidIdx = rriInvalidIdxBase;
                return
            end

            rriValues = rriTable.RRI;
            if isempty(rriValues)
                rriInvalidIdx = rriInvalidIdxBase;
                return
            end

            rriCount = numel(rriValues);
            sampleIdx = obj.rriStateManager.getRriSampleIdxForCurrentState(rriCount, ...
                useReviewedState, obj.peaksRawIdx, obj.peaksReviewedIdx, ...
                fallbackPeaks, nSamples, obj.rri);
            mappedCount = min(rriCount, numel(sampleIdx));
            if mappedCount < 1
                rriInvalidIdx = rriInvalidIdxBase;
                return
            end

            sampleIdx = sampleIdx(1:mappedCount);
            rriValues = rriValues(1:mappedCount);
            lowerMask = rriValues < obj.lowLimitRRI;
            highMask = rriValues >= obj.highLimitRRI;
            lowCandidates = sampleIdx(lowerMask);
            highCandidates = sampleIdx(highMask);
            newInvalid = sampleIdx(lowerMask | highMask);
            rriInvalidIdx = unique([rriInvalidIdxBase(:); newInvalid(:)], 'stable');
            rriInvalidIdx = obj.rriStateManager.normalizeInvalidForPeaks(rriInvalidIdx, rriPeaksIdx, nSamples);

            if any(lowerMask | highMask)
                lowToLog = lowCandidates(~ismember(lowCandidates, rriInvalidIdxBase));
                highToLog = highCandidates(~ismember(highCandidates, rriInvalidIdxBase));
                [userId, sessionId] = obj.artifactLogManager.createAutoReviewIdentity("semiauto");
                obj.artifactLogManager.appendAutoRriEdits( ...
                    lowToLog, "delete", "auto_semiauto_low_limit", userId, sessionId, ...
                    obj.getPeakTimesForSampleIdx(lowToLog), obj.fs);
                obj.artifactLogManager.appendAutoRriEdits( ...
                    highToLog, "delete", "auto_semiauto_high_limit", userId, sessionId, ...
                    obj.getPeakTimesForSampleIdx(highToLog), obj.fs);
            end

            if useReviewedState
                obj.rriStateManager.setReviewedIndices(rriPeaksIdx, rriInvalidIdx, ...
                    obj.peaksRawIdx, obj.peaksReviewedIdx, fallbackPeaks, nSamples, obj.rri);
            end
        end

        function rriData = removeRriOutOfRange(obj, rriData)
            obj.ensureArtifactLogManager();
            obj.ensureRriStateManager();
            [userId, sessionId] = obj.artifactLogManager.createAutoReviewIdentity("drop");
            if isempty(rriData) || ~istable(rriData) || ...
                    ~ismember('RRI', rriData.Properties.VariableNames)
                return
            end

            lowerMask = rriData.RRI < obj.lowLimitRRI;
            highMask = rriData.RRI >= obj.highLimitRRI;
            rriCount = height(rriData);
            nSamples = obj.getCurrentSampleCount();
            fallbackPeaks = obj.getInitialPeaksForManualReview();
            sampleIdx = obj.rriStateManager.getRriSampleIdxForCurrentState(rriCount, true, ...
                obj.peaksRawIdx, obj.peaksReviewedIdx, fallbackPeaks, nSamples, obj.rri);
            lowerSampleIdx = sampleIdx(lowerMask);
            highSampleIdx = sampleIdx(highMask);

            obj.artifactLogManager.appendAutoRriEdits( ...
                lowerSampleIdx, "delete", "auto_drop_low_limit", userId, sessionId, ...
                obj.getPeakTimesForSampleIdx(lowerSampleIdx), obj.fs);
            obj.artifactLogManager.appendAutoRriEdits( ...
                highSampleIdx, "delete", "auto_drop_high_limit", userId, sessionId, ...
                obj.getPeakTimesForSampleIdx(highSampleIdx), obj.fs);

            maskToKeep = ~(lowerMask | highMask);
            removedSampleIdx = sampleIdx(~maskToKeep);
            rriData = rriData(maskToKeep, :);

            obj.rriStateManager.appendInvalidSamples(removedSampleIdx, ...
                obj.peaksRawIdx, obj.peaksReviewedIdx, fallbackPeaks, nSamples, rriData);
        end

        function ensureArtifactLogManager(obj)
            if isempty(obj.artifactLogManager) || ~isvalid(obj.artifactLogManager)
                obj.artifactLogManager = ECGArtifactLogManager();
            end
        end

        function ensureRriStateManager(obj)
            if isempty(obj.rriStateManager) || ~isvalid(obj.rriStateManager)
                obj.rriStateManager = ECGRriReviewStateManager();
            end
        end

        function timestamps = getSourceEcgTimestamps(obj)
            timestamps = [];
            if ~isempty(obj.sourceECG) && istable(obj.sourceECG) && ...
                    ismember('Timestamp', obj.sourceECG.Properties.VariableNames)
                timestamps = obj.sourceECG.Timestamp;
            end
        end

        function peakTimes = getPeakTimesForSampleIdx(obj, sampleIdx)
            if isempty(sampleIdx)
                peakTimes = strings(0,1);
                return
            end

            sampleIdx = double(sampleIdx(:));
            peakTimes = repmat("", numel(sampleIdx), 1);
            validMask = isfinite(sampleIdx);
            if ~any(validMask)
                return
            end

            sampleIdxRounded = round(sampleIdx(validMask));
            outRows = find(validMask);
            if ~isempty(obj.fs) && isfinite(obj.fs) && obj.fs > 0
                peakTimes(outRows) = string(seconds((sampleIdxRounded - 1) ./ obj.fs));
            end
        end

        function hydrateAutoArtifactState(obj, opts)
            obj.ensureRriStateManager();
            nSamples = obj.getCurrentSampleCount();
            fallbackPeaks = obj.getInitialPeaksForManualReview();
            obj.rriStateManager.ensureScaffold(obj.rri, obj.peaksRawIdx, obj.peaksReviewedIdx, ...
                fallbackPeaks, nSamples);

            if ~isfield(opts, 'resumeIfExists') || ~opts.resumeIfExists
                return
            end

            qcDir = ECGRriArtifactRejectionService.getManualInspectionQcDir(struct("saveDir", opts.ecgQCSaveDir));
            if strlength(qcDir) == 0 || exist(qcDir, 'dir') ~= 7
                return
            end

            [resumeAvailable, resumeData] = ECGRriReviewStateManager.loadResumeState( ...
                qcDir, nSamples, obj.peaksRawIdx);
            if ~resumeAvailable
                return
            end

            [obj.peaksRawIdx, obj.peaksReviewedIdx, obj.rri] = obj.rriStateManager.applyResumeState( ...
                resumeData, obj.peaksRawIdx, obj.peaksReviewedIdx, fallbackPeaks, ...
                nSamples, obj.rri, @(x)obj.computeRriFromPeaks(x));
        end

        function saveManualInspectionQc(obj, opts)
            qcDir = ECGRriArtifactRejectionService.getManualInspectionQcDir(opts);
            if strlength(qcDir) == 0
                warning('ECG:ManualInspectionNoSaveDir', ...
                    'saveQCArtifacts is true but no saveDir provided; skipping QC artifact saving.');
                return
            end

            if ~exist(qcDir, 'dir')
                mkdir(qcDir);
            end

            % manualQC = obj.manualQC;
            % if isstruct(manualQC) && ~isempty(fieldnames(manualQC))
            %     save(fullfile(qcDir, 'qc_summary.mat'), 'manualQC');
            % end
            % 
            % if ~isempty(obj.manualReviewLog)
            %     reviewLog = obj.manualReviewLog;
            %     save(fullfile(qcDir, 'review_log.mat'), 'reviewLog');
            % end
            % if ~isempty(obj.manualFlaggedWindows)
            %     flaggedWindows = obj.manualFlaggedWindows;
            %     save(fullfile(qcDir, 'flagged_windows.mat'), 'flaggedWindows');
            % end
            % 
            % peaksRawIdx = obj.peaksRawIdx;
            % save(fullfile(qcDir, 'peaks_raw.mat'), 'peaksRawIdx');
            % peaksReviewedIdx = obj.peaksReviewedIdx;
            % save(fullfile(qcDir, 'peaks_reviewed.mat'), 'peaksReviewedIdx');

            obj.saveReviewLogsAt(qcDir);

            % if isfield(opts, 'returnFigures') && opts.returnFigures && isstruct(obj.manualFigures)
            %     obj.exportManualFigures(qcDir);
            % end
        end

        function exportManualFigures(obj, qcDir)
            fields = {'ekgPlot','ibiPlot'};
            for i = 1:numel(fields)
                f = fields{i};
                if isfield(obj.manualFigures, f) && ~isempty(obj.manualFigures.(f)) ...
                        && isgraphics(obj.manualFigures.(f))
                    try
                        exportgraphics(obj.manualFigures.(f), fullfile(qcDir, [f '.png']));
                    catch
                        warning('ECG:ManualInspectionFigureExportFailed', ...
                            'Failed to export figure %s.', f);
                    end
                end
            end
        end

        function nSamples = getCurrentSampleCount(obj)
            nSamples = ECGRriReviewStateManager.resolveSampleCount(obj.sourceECG, [], obj.peaksRawIdx);
        end

        function [capSampleIdx, capValuesMs] = extractTrimCapsFromEditLogs(obj, editLogs)
            capSampleIdx = zeros(0,1);
            capValuesMs = zeros(0,1);
            if ~istable(editLogs) || isempty(editLogs)
                return
            end

            editLogs = ECGManualInspector.normalizeEditLogTable(editLogs);
            if isempty(editLogs) || ...
                    ~all(ismember({'action','note','peak_before','peak_after'}, editLogs.Properties.VariableNames))
                return
            end

            action = lower(strtrim(string(editLogs.action)));
            note = lower(strtrim(string(editLogs.note)));
            if ismember('editTarget', editLogs.Properties.VariableNames)
                editTarget = lower(strtrim(string(editLogs.editTarget)));
            else
                editTarget = ECGManualInspector.defaultEditTargetFromActionNote(action, note);
            end
            lowMask = action == "cap" & note == "auto_trim_low_limit" & editTarget == "rri_peak";
            highMask = action == "cap" & note == "auto_trim_high_limit" & editTarget == "rri_peak";
            if ~any(lowMask | highMask)
                return
            end

            capRows = find(lowMask | highMask);
            capSampleIdx = double(editLogs.peak_after(capRows));
            capBefore = double(editLogs.peak_before(capRows));
            capSampleIdx(~isfinite(capSampleIdx)) = capBefore(~isfinite(capSampleIdx));
            capValuesMs = repmat(obj.highLimitRRI, numel(capRows), 1);
            lowRowsMask = note(capRows) == "auto_trim_low_limit";
            capValuesMs(lowRowsMask) = obj.lowLimitRRI;

            validMask = isfinite(capSampleIdx) & capSampleIdx >= 1 & isfinite(capValuesMs);
            capSampleIdx = round(capSampleIdx(validMask));
            capValuesMs = capValuesMs(validMask);
            if isempty(capSampleIdx)
                return
            end

            [sampleStable, ~, groupIdx] = unique(capSampleIdx, 'stable');
            valueStable = zeros(numel(sampleStable), 1);
            for i = 1:numel(sampleStable)
                valueStable(i) = capValuesMs(find(groupIdx == i, 1, 'last')); %#ok<FNDSB>
            end
            capSampleIdx = sampleStable;
            capValuesMs = valueStable;
        end

        function rriData = applyTrimCapsToRri(obj, rriData, capSampleIdx, capValuesMs)
            if isempty(capSampleIdx) || isempty(capValuesMs) || ...
                    ~istable(rriData) || ~ismember('RRI', rriData.Properties.VariableNames)
                return
            end
            if numel(capSampleIdx) ~= numel(capValuesMs)
                return
            end

            obj.ensureRriStateManager();
            rriCount = height(rriData);
            if rriCount < 1
                return
            end

            nSamples = obj.getCurrentSampleCount();
            fallbackPeaks = obj.getInitialPeaksForManualReview();
            sampleIdx = obj.rriStateManager.getRriSampleIdxForCurrentState(rriCount, true, ...
                obj.peaksRawIdx, obj.peaksReviewedIdx, fallbackPeaks, nSamples, rriData);
            if isempty(sampleIdx)
                return
            end

            [hasCap, capPos] = ismember(sampleIdx(:), capSampleIdx(:));
            if ~any(hasCap)
                return
            end

            capTargetRows = find(hasCap);
            rriData.RRI(capTargetRows) = capValuesMs(capPos(hasCap));
            obj.rriStateManager.setReviewedRri(rriData);
        end
    end

    methods (Static)
        function timeVector = getTimeVector(pointsInVector, fs)
            timeVector = 0 : 1/fs : 1/fs*(pointsInVector-1);
        end

        function rriData = getRRITableFromPeakLocations(timestamps, ind_locs)
            locs = timestamps(ind_locs);
            rri = seconds(diff(locs))*1e3;
            rri_timestamp = locs(2:end);
            rriData = table(rri_timestamp, rri, 'VariableNames', {'Timestamp','RRI'});
        end
    end

    methods (Static, Access=private)
        function method = normalizeArtifactRejectionMethod(method)
            method = lower(strtrim(string(method)));
            if method == "ignore"
                method = "drop";
            end
        end

        function qcDir = getManualInspectionQcDir(opts)
            if isfield(opts, 'qcDirOverride') && strlength(opts.qcDirOverride) > 0
                qcDir = string(opts.qcDirOverride);
                return
            end
            if ~isfield(opts, 'saveDir') || isempty(opts.saveDir)
                qcDir = "";
                return
            end
            qcDir = string(fullfile(opts.saveDir, 'qc', 'ecgReview'));
        end

        function opts = applyManualInspectionDefaults(opts)
            defaults.launchUI = true;
            defaults.userId = "";
            defaults.sessionId = char(java.util.UUID.randomUUID);
            defaults.returnFigures = true;
            defaults.verbose = true;
            defaults.saveQCArtifacts = true;
            defaults.saveDir = "";
            defaults.resumeIfExists = true;
            defaults.qcDirOverride = "";
            defaults.rriPeaksIdxInit = [];
            defaults.rriInvalidIdxInit = [];

            fields = fieldnames(defaults);
            for i = 1:numel(fields)
                f = fields{i};
                if ~isfield(opts, f) || isempty(opts.(f))
                    opts.(f) = defaults.(f);
                end
            end

            if strlength(opts.userId) == 0
                userName = getenv('USERNAME');
                if isempty(userName)
                    userName = getenv('USER');
                end
                opts.userId = string(userName);
            end
        end
        
        function ensureManualReviewPath()
            persistent isReady
            if ~isempty(isReady) && isReady
                return
            end
            if exist('manualReviewECGPeaks', 'file') == 2
                isReady = true;
                return
            end
            baseDir = fileparts(fileparts(mfilename('fullpath')));
            ecgDir = fullfile(baseDir, 'ecg');
            reviewDir = fullfile(ecgDir, 'manual_review');
            if exist(baseDir, 'dir')
                addpath(baseDir);
            end
            if exist(ecgDir, 'dir')
                addpath(ecgDir);
            end
            if exist(reviewDir, 'dir')
                addpath(reviewDir);
            end
            isReady = true;
        end
        
        function ensureManualReviewPath_new()
            hasManualUiClass = exist('ECGManualUI', 'class') == 8 || ...
                               exist('ECGManualUI', 'file') == 2;
            hasManualInspectorClass = exist('ECGManualInspector', 'class') == 8 || ...
                                      exist('ECGManualInspector', 'file') == 2;
            if hasManualUiClass && hasManualInspectorClass
                return
            end
            error('ECG:MissingManualReviewClasses', ...
                ['ECG manual review classes are not on the MATLAB path. ', ...
                 'Ensure utils/ is added before running manual or semiauto review.']);
        end

        function opts = applyRunDefaults(opts)
            defaults = struct('ecgArtifactRejectionMethod', "trim", ...
                'ecgQCSaveDir', "", 'resumeIfExists', true, 'verbose', false);
            fields = fieldnames(defaults);
            for i = 1:numel(fields)
                f = fields{i};
                if ~isfield(opts, f) || isempty(opts.(f))
                    opts.(f) = defaults.(f);
                end
            end
        end
    end
end
