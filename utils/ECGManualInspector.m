classdef ECGManualInspector < handle
    properties
        ecg
        fs
        peaksRawIdx
        peaksIdx
        editLog
        reviewLog
        flaggedWindows
        qcBefore
        qcAfter
        figHandles
        opts
        undoStack
        redoStack
        ui
    end

    properties (Access=private)
        peaksAmp
        uiActive = false
        ecgTimestamps
        initialUiState
        cancelled = false
    end

    methods
        function obj = ECGManualInspector(ecg, fs, peaksInit, opts)
            if nargin < 4 || isempty(opts)
                opts = struct();
            end

            obj.opts = ECGManualInspector.applyDefaultOpts(opts);
            obj.validateInputs(ecg, fs, peaksInit);

            obj.ecg = double(ecg(:));
            obj.fs = double(fs);
            nSamples = numel(obj.ecg);
            obj.ecgTimestamps = obj.sanitizeEcgTimestamps(obj.opts.ecgTimestamps, nSamples);

            peaksRaw = peaksInit;
            if obj.opts.resume && ~isempty(obj.opts.peaksRawIdxOverride)
                peaksRaw = obj.opts.peaksRawIdxOverride;
            end

            if obj.opts.resume && ~isempty(obj.opts.peaksReviewedIdxInit)
                obj.validatePeaksInit(peaksRaw, nSamples);
                peaksRaw = obj.sanitizePeaks(peaksRaw, nSamples);
                peaksReviewed = obj.sanitizePeaks(obj.opts.peaksReviewedIdxInit, nSamples);
                if isempty(peaksReviewed)
                    peaksReviewed = peaksRaw;
                end
                peaksAmp = obj.ecg(peaksReviewed);
            else
                if isempty(peaksRaw) && obj.opts.computeIfEmpty
                    [peaksRaw, peaksAmp] = obj.computeInitialPeaks(obj.ecg, obj.fs);
                else
                    obj.validatePeaksInit(peaksRaw, nSamples);
                    peaksRaw = obj.sanitizePeaks(peaksRaw, nSamples);
                    peaksAmp = obj.ecg(peaksRaw);
                end
                peaksReviewed = peaksRaw;
            end

            obj.peaksRawIdx = peaksRaw(:);
            obj.peaksIdx = peaksReviewed(:);
            obj.peaksAmp = peaksAmp(:);

            [obj.peaksIdx, obj.peaksAmp] = obj.sortPeaks(obj.peaksIdx, obj.peaksAmp);

            obj.editLog = obj.initEditLog();

            if obj.opts.resume && istable(obj.opts.editLogsInit) && ~isempty(obj.opts.editLogsInit)
                obj.editLog = ECGManualInspector.normalizeEditLogTable(obj.opts.editLogsInit);
            end

            obj.reviewLog = obj.opts.reviewLogInit;
            obj.flaggedWindows = obj.opts.flaggedWindows;

            obj.qcBefore = obj.computeQC(obj.peaksRawIdx);
            obj.qcAfter = struct();
            obj.figHandles = struct();
            obj.undoStack = {};
            obj.redoStack = {};
            obj.ui = [];
            obj.initialUiState = struct();
            obj.cancelled = false;
        end

        function run(obj)
            if ~obj.opts.launchUI
                obj.qcAfter = obj.computeQC(obj.peaksIdx);
                return
            end

            obj.uiActive = true;
            obj.installGlobalInspector();
            obj.initGlobalEkgState();

            obj.ui = ECGManualUI(obj);
            obj.ui.initEkgPlot();
            obj.ui.initEkgControl();
            obj.ui.initIbiPlot();
            obj.ui.initPsdPlot();

            if isempty(obj.peaksIdx) && obj.opts.computeIfEmpty
                obj.ui.findPeaks();
            else
                obj.ui.drawEkgPlot();
                if numel(obj.peaksIdx) >= 2
                    obj.ui.drawIbiPlot();
                    obj.ui.drawPsdPlot();
                end
            end
            obj.initialUiState = obj.captureState();
            obj.undoStack = {};
            obj.redoStack = {};

            hControl = findobj('Tag', 'FigureEkgControl');
            if ~isempty(hControl) && ishandle(hControl)
                waitfor(hControl);
            else
                hPlot = findobj('Tag', 'FigureEkgPlot');
                if ~isempty(hPlot) && ishandle(hPlot)
                    waitfor(hPlot);
                end
            end

            if obj.cancelled
                obj.restoreInitialUiState();
                obj.qcAfter = obj.computeQC(obj.peaksIdx);
                obj.uiActive = false;
                return
            end

            if obj.opts.returnFigures
                obj.figHandles = obj.collectFigureHandles();
                obj.figHandles = obj.pruneFigureHandles(obj.figHandles);
            end

            obj.qcAfter = obj.computeQC(obj.peaksIdx);
            obj.uiActive = false;
        end

        function insertPeak(obj, sampleIdx, note, varargin)
            obj.applyEdit("insert", sampleIdx, sampleIdx, note, varargin{:});
        end

        function deletePeak(obj, sampleIdx, note)
            obj.deletePeaks(sampleIdx, note);
        end

        function deletePeaks(obj, sampleIdx, note)
            if nargin < 3
                note = "";
            end

            [peakBefore, peakAfter] = obj.applyDeleteBatch(sampleIdx);
            if isempty(peakBefore)
                return
            end

            obj.refreshRriForCurrentWindow();
            obj.appendLog("delete", peakBefore, peakAfter, note, "ecg_peak");
            obj.syncUiAfterEdit();
        end

        function movePeak(obj, oldSampleIdx, newSampleIdx, note, varargin)
            obj.applyEdit("move", oldSampleIdx, newSampleIdx, note, varargin{:});
        end

        function updatePeakAmplitude(obj, sampleIdx, newAmplitude, note)
            if nargin < 4
                note = "";
            end
            [idx, peakPos] = obj.findPeak(sampleIdx);
            if isempty(idx)
                return
            end
            obj.pushUndoState();
            obj.redoStack = {};
            obj.peaksAmp(peakPos) = newAmplitude;
            obj.appendLog("move_amp", sampleIdx, sampleIdx, note, "ecg_peak");
            obj.syncUiAfterEdit();
        end

        function beginUiEdit(obj)
            obj.pushUndoState();
            obj.redoStack = {};
        end

        function logRriEdit(obj, action, peakBefore, peakAfter, note, editTarget)
            if nargin < 5
                note = "";
            end
            if nargin < 6 || strlength(editTarget) == 0
                if lower(strtrim(string(action))) == "delete"
                    editTarget = "rri_invalid";
                else
                    editTarget = "rri_peak";
                end
            end
            obj.appendLog(action, peakBefore, peakAfter, note, editTarget);
        end

        function undo(obj)
            if isempty(obj.undoStack)
                return
            end
            obj.redoStack{end+1} = obj.captureState();
            state = obj.undoStack{end};
            obj.undoStack(end) = [];
            obj.restoreState(state);
            obj.syncUiAfterEdit();
        end

        function redo(obj)
            if isempty(obj.redoStack)
                return
            end
            obj.undoStack{end+1} = obj.captureState();
            state = obj.redoStack{end};
            obj.redoStack(end) = [];
            obj.restoreState(state);
            obj.syncUiAfterEdit();
        end

        function startOver(obj)
            obj.restoreInitialUiState();
            obj.undoStack = {};
            obj.redoStack = {};
            obj.cancelled = false;
            obj.syncUiAfterEdit();
        end

        function cancelReview(obj)
            obj.restoreInitialUiState();
            obj.undoStack = {};
            obj.redoStack = {};
            obj.cancelled = true;
            if obj.uiActive
                obj.syncGlobalPeaks();
            end
        end

        function tf = wasCancelled(obj)
            tf = obj.cancelled;
        end

        function [peaksReviewed, editLog, qc, figHandles] = exportResults(obj)
            peaksReviewed = obj.peaksIdx(:);
            editLog = obj.editLog;
            qc = obj.buildQcSummary();
            figHandles = obj.figHandles;
        end

        function [rriPeaksIdx, rriInvalidIdx] = exportRriEdits(obj)
            global EKG;
            rriPeaksIdx = zeros(0,1);
            rriInvalidIdx = zeros(0,1);
            if isempty(EKG) || ~isfield(EKG, 'rriCustomActive') || ~EKG.rriCustomActive
                return
            end
            if isfield(EKG, 'rriPeaksIdx') && ~isempty(EKG.rriPeaksIdx)
                rriPeaksIdx = obj.sanitizePeaks(EKG.rriPeaksIdx, numel(obj.ecg));
            end
            if isfield(EKG, 'rriInvalidIdx') && ~isempty(EKG.rriInvalidIdx)
                rriInvalidIdx = double(EKG.rriInvalidIdx(:));
                rriInvalidIdx = rriInvalidIdx(isfinite(rriInvalidIdx));
                rriInvalidIdx = round(rriInvalidIdx);
            end
            if numel(rriPeaksIdx) < 2
                rriInvalidIdx = zeros(0,1);
                return
            end
            validIbiPeaks = rriPeaksIdx(2:end);
            rriInvalidIdx = rriInvalidIdx(ismember(rriInvalidIdx, validIbiPeaks));
            rriInvalidIdx = unique(rriInvalidIdx, 'stable');
        end

        function setPeaksFromUi(obj, peaksIdx, peaksAmp)
            if isempty(peaksIdx)
                obj.peaksIdx = zeros(0, 1);
                obj.peaksAmp = zeros(0, 1);
                if obj.uiActive
                    obj.resetRriToEcg();
                    obj.syncGlobalPeaks();
                end
                return
            end
            peaksIdx = obj.sanitizePeaks(peaksIdx, numel(obj.ecg));
            peaksAmp = peaksAmp(:);
            if numel(peaksAmp) ~= numel(peaksIdx)
                peaksAmp = obj.ecg(peaksIdx);
            end
            [obj.peaksIdx, obj.peaksAmp] = obj.sortPeaks(peaksIdx, peaksAmp);
            if obj.uiActive
                obj.resetRriToEcg();
                obj.syncGlobalPeaks();
            end
        end
    end

    methods (Access=private)
        function validateInputs(~, ecg, fs, peaksInit)
            if ~(isnumeric(ecg) && isvector(ecg) && ~isempty(ecg))
                error('ECGManualInspector:InvalidECG', 'ecg must be a non-empty vector.');
            end
            if ~(isnumeric(fs) && isscalar(fs) && isfinite(fs) && fs > 0)
                error('ECGManualInspector:InvalidFs', 'fs must be a positive scalar.');
            end
            if ~(isnumeric(peaksInit) && isvector(peaksInit))
                error('ECGManualInspector:InvalidPeaks', 'peaksInit must be a numeric vector.');
            end
        end

        function validatePeaksInit(~, peaks, nSamples)
            if isempty(peaks)
                return
            end
            peaks = double(peaks(:));
            if any(~isfinite(peaks))
                error('ECGManualInspector:InvalidPeaks', 'peaksInit must be finite.');
            end
            if any(peaks < 1) || any(peaks > nSamples)
                error('ECGManualInspector:OutOfBounds', 'peaksInit must be within [1..N].');
            end
        end

        function peaks = sanitizePeaks(~, peaks, nSamples)
            if isempty(peaks)
                peaks = zeros(0,1);
                return
            end
            peaks = double(peaks(:));
            peaks = peaks(isfinite(peaks));
            peaks = round(peaks);
            peaks = peaks(peaks >= 1 & peaks <= nSamples);
            peaks = unique(peaks);
        end

        function [idx, pos] = findPeak(obj, sampleIdx)
            if isempty(obj.peaksIdx)
                idx = [];
                pos = [];
                return
            end
            pos = find(obj.peaksIdx == sampleIdx, 1, 'first');
            if isempty(pos)
                idx = [];
            else
                idx = obj.peaksIdx(pos);
            end
        end

        function applyEdit(obj, action, peakBefore, peakAfter, note, varargin)
            if nargin < 5
                note = "";
            end
            newAmplitude = [];
            if ~isempty(varargin)
                newAmplitude = varargin{1};
            end

            obj.pushUndoState();
            obj.redoStack = {};

            switch action
                case "insert"
                    obj.applyInsert(peakAfter, newAmplitude);
                case "delete"
                    obj.applyDelete(peakBefore);
                case "move"
                    obj.applyMove(peakBefore, peakAfter, newAmplitude);
            end

            if action == "insert" || action == "delete" || action == "move"
                obj.refreshRriForCurrentWindow();
            end

            obj.appendLog(action, peakBefore, peakAfter, note, "ecg_peak");
            obj.syncUiAfterEdit();
        end

        function applyInsert(obj, sampleIdx, newAmplitude)
            sampleIdx = obj.sanitizePeaks(sampleIdx, numel(obj.ecg));
            if isempty(sampleIdx)
                return
            end
            if isempty(newAmplitude)
                newAmplitude = obj.ecg(sampleIdx);
            end
            obj.peaksIdx(end+1,1) = sampleIdx;
            obj.peaksAmp(end+1,1) = newAmplitude;
            [obj.peaksIdx, obj.peaksAmp] = obj.sortPeaks(obj.peaksIdx, obj.peaksAmp);
        end

        function applyDelete(obj, sampleIdx)
            if isempty(obj.peaksIdx)
                return
            end
            [~, pos] = obj.findPeak(sampleIdx);
            if isempty(pos)
                return
            end
            obj.peaksIdx(pos) = [];
            obj.peaksAmp(pos) = [];
        end

        function [peakBefore, peakAfter] = applyDeleteBatch(obj, sampleIdx)
            peakBefore = zeros(0,1);
            peakAfter = zeros(0,1);
            if isempty(obj.peaksIdx) || isempty(sampleIdx)
                return
            end

            requestedPeaks = obj.sanitizePeaks(sampleIdx, numel(obj.ecg));
            if isempty(requestedPeaks)
                return
            end

            [isExistingPeak, positions] = ismember(requestedPeaks, obj.peaksIdx);
            positions = positions(isExistingPeak);
            if isempty(positions)
                return
            end

            positions = unique(positions, 'stable');
            peakBefore = obj.peaksIdx(positions);
            peakAfter = peakBefore;

            obj.pushUndoState();
            obj.redoStack = {};
            obj.peaksIdx(positions) = [];
            obj.peaksAmp(positions) = [];
        end

        function applyMove(obj, oldSampleIdx, newSampleIdx, newAmplitude)
            if isempty(obj.peaksIdx)
                return
            end
            [~, pos] = obj.findPeak(oldSampleIdx);
            if isempty(pos)
                return
            end
            newSampleIdx = obj.sanitizePeaks(newSampleIdx, numel(obj.ecg));
            if isempty(newSampleIdx)
                return
            end
            obj.peaksIdx(pos) = newSampleIdx;
            if ~isempty(newAmplitude)
                obj.peaksAmp(pos) = newAmplitude;
            end
            [obj.peaksIdx, obj.peaksAmp] = obj.sortPeaks(obj.peaksIdx, obj.peaksAmp);
        end

        function pushUndoState(obj)
            obj.undoStack{end+1} = obj.captureState();
        end

        function state = captureState(obj)
            global EKG;
            state = struct();
            state.peaksIdx = obj.peaksIdx;
            state.peaksAmp = obj.peaksAmp;
            state.editLog = obj.editLog;
            state.reviewLog = obj.reviewLog;
            state.flaggedWindows = obj.flaggedWindows;
            state.hasEkgState = ~isempty(EKG) && isstruct(EKG);
            if state.hasEkgState
                state.ekg = struct();
                state.ekg.rriCustomActive = ECGManualInspector.getStructField(EKG, 'rriCustomActive', false);
                state.ekg.rriPeaksIdx = ECGManualInspector.getStructField(EKG, 'rriPeaksIdx', []);
                state.ekg.rriInvalidIdx = ECGManualInspector.getStructField(EKG, 'rriInvalidIdx', []);
                state.ekg.rriCapSampleIdx = ECGManualInspector.getStructField(EKG, 'rriCapSampleIdx', zeros(0,1));
                state.ekg.rriCapValuesMs = ECGManualInspector.getStructField(EKG, 'rriCapValuesMs', zeros(0,1));
                state.ekg.plot = ECGManualInspector.getStructField(EKG, 'plot', struct());
                state.ekg.threshold = ECGManualInspector.getStructField(EKG, 'threshold', []);
                state.ekg.HF_lower = ECGManualInspector.getStructField(EKG, 'HF_lower', []);
                state.ekg.HF_upper = ECGManualInspector.getStructField(EKG, 'HF_upper', []);
                state.ekg.RSPpointDown = ECGManualInspector.getStructField(EKG, 'RSPpointDown', []);
                state.ekg.RSPpointUp = ECGManualInspector.getStructField(EKG, 'RSPpointUp', []);
                state.ekg.rspBoundExists = ECGManualInspector.getStructField(EKG, 'rspBoundExists', []);
            end
        end

        function restoreState(obj, state)
            global EKG;
            obj.peaksIdx = state.peaksIdx;
            obj.peaksAmp = state.peaksAmp;
            if isfield(state, 'editLog')
                obj.editLog = state.editLog;
            end
            if isfield(state, 'reviewLog')
                obj.reviewLog = state.reviewLog;
            end
            if isfield(state, 'flaggedWindows')
                obj.flaggedWindows = state.flaggedWindows;
            end
            if isfield(state, 'hasEkgState') && state.hasEkgState && ...
                    isfield(state, 'ekg') && ~isempty(EKG) && isstruct(EKG)
                EKG.rriCustomActive = state.ekg.rriCustomActive;
                EKG.rriPeaksIdx = state.ekg.rriPeaksIdx;
                EKG.rriInvalidIdx = state.ekg.rriInvalidIdx;
                EKG.rriCapSampleIdx = state.ekg.rriCapSampleIdx;
                EKG.rriCapValuesMs = state.ekg.rriCapValuesMs;
                if isfield(state.ekg, 'plot') && ~isempty(state.ekg.plot)
                    EKG.plot = state.ekg.plot;
                end
                restoreFields = {'threshold','HF_lower','HF_upper','RSPpointDown','RSPpointUp','rspBoundExists'};
                for iField = 1:numel(restoreFields)
                    fieldName = restoreFields{iField};
                    if isfield(state.ekg, fieldName) && ~isempty(state.ekg.(fieldName))
                        EKG.(fieldName) = state.ekg.(fieldName);
                    end
                end
            end
        end

        function restoreInitialUiState(obj)
            if isstruct(obj.initialUiState) && isfield(obj.initialUiState, 'peaksIdx')
                obj.restoreState(obj.initialUiState);
            end
        end

        function appendLog(obj, action, peakBefore, peakAfter, note, editTarget)
            if nargin < 5
                note = "";
            end
            if nargin < 6 || strlength(editTarget) == 0
                editTarget = ECGManualInspector.defaultEditTargetFromActionNote(action, note);
            end
            peakTimeBefore = obj.resolvePeakTimeText(peakBefore);
            peakTimeAfter = obj.resolvePeakTimeText(peakAfter);
            row = ECGManualInspector.buildEditLogRows(action, peakBefore, peakAfter, ...
                note, obj.opts.userId, obj.opts.sessionId, [], peakTimeBefore, peakTimeAfter, editTarget);
            obj.editLog = [obj.editLog; row];
        end

        function editLog = initEditLog(~)
            editLog = ECGManualInspector.initEditLogTable();
        end

        function qc = computeQC(obj, peaksIdx)
            qc = struct();
            qc.nPeaks = numel(peaksIdx);
            qc.ibi_ms = obj.computeIbi(peaksIdx, obj.fs);
            if isempty(qc.ibi_ms)
                qc.meanHR_bpm = nan;
                qc.sdnn_ms = nan;
                qc.rmssd_ms = nan;
                return
            end
            qc.meanHR_bpm = 60000 / mean(qc.ibi_ms);
            qc.sdnn_ms = std(qc.ibi_ms);
            diffIbi = diff(qc.ibi_ms);
            qc.rmssd_ms = sqrt(mean(diffIbi .^ 2));
        end

        function qc = buildQcSummary(obj)
            qc = struct();
            qc.nInitial = numel(obj.peaksRawIdx);
            qc.nFinal = numel(obj.peaksIdx);
            if isempty(obj.editLog)
                qc.nInserted = 0;
                qc.nDeleted = 0;
                qc.nMoved = 0;
            else
                qc.nInserted = sum(obj.editLog.action == "insert");
                qc.nDeleted = sum(obj.editLog.action == "delete");
                qc.nMoved = sum(obj.editLog.action == "move");
            end
            qc.fs = obj.fs;
            qc.nSamples = numel(obj.ecg);
            qc.ibiInitial_ms = obj.qcBefore.ibi_ms;
            qc.ibiFinal_ms = obj.qcAfter.ibi_ms;
            qc.before = obj.qcBefore;
            qc.after = obj.qcAfter;
        end

        function ibi = computeIbi(~, peaks, fs)
            if numel(peaks) < 2
                ibi = zeros(0,1);
                return
            end
            peaks = sort(peaks(:));
            ibi = diff(peaks) / fs * 1000;
        end

        function [peaksIdx, peaksAmp] = computeInitialPeaks(~, ecg, fs)
            threshold = std(ecg);
            minSampsBetweenPeaks = 400*fs/1000;
            peaksMat = peakfinder(ecg, threshold, minSampsBetweenPeaks);
            while isempty(peaksMat)
                peaksMat = peakfinder(ecg, threshold, minSampsBetweenPeaks);
            end
            peaksIdx = peaksMat(:,1);
            peaksAmp = peaksMat(:,2);
        end

        function [sortedIdx, sortedAmp] = sortPeaks(~, peaksIdx, peaksAmp)
            if isempty(peaksIdx)
                sortedIdx = zeros(0,1);
                sortedAmp = zeros(0,1);
                return
            end
            [sortedIdx, order] = sort(peaksIdx);
            sortedAmp = peaksAmp(order);
            [sortedIdx, uniqueIdx] = unique(sortedIdx, 'stable');
            sortedAmp = sortedAmp(uniqueIdx);
        end

        function installGlobalInspector(obj)
            global ECG_MANUAL_INSPECTOR;
            ECG_MANUAL_INSPECTOR = obj;
        end

        function initGlobalEkgState(obj)
            global EKG;
            EKG = struct();
            EKG.inFile = char(obj.opts.sessionId);
            EKG.sampRate = obj.fs;
            EKG.signal = obj.ecg;
            EKG.ibis = [];
            EKG.peaks = [];
            EKG.t_peaks = [];
            EKG.time_second_peak = [];
            EKG.threshold = std(EKG.signal);
            EKG.plot.maxTime = length(EKG.signal)/EKG.sampRate;
            initialWindow = min(60, EKG.plot.maxTime);
            startTime = 0;
            EKG.plot.startTime = startTime;
            EKG.plot.widthTime = initialWindow;
            EKG.plot.endTime = EKG.plot.startTime + EKG.plot.widthTime;
            EKG.plot.incrUpDn = EKG.threshold/20;
            EKG.plot.incrLR = (EKG.plot.endTime-EKG.plot.startTime);
            EKG.HF_lower = 0.15;
            EKG.HF_upper = 0.40;
            EKG.RSP.signal = [];
            EKG.dataSource = char(obj.opts.dataSource);
            EKG.RSPpointDown = EKG.plot.startTime;
            EKG.RSPpointUp = EKG.plot.endTime;
            EKG.rspBoundExists = 0;
            EKG.ekgPeakExists = 0;
            EKG.rriCustomActive = false;
            EKG.rriPeaksIdx = [];
            EKG.rriInvalidIdx = [];
            EKG.rriCapSampleIdx = zeros(0,1);
            EKG.rriCapValuesMs = zeros(0,1);
            EKG.parameter1 = obj.opts.parameter1;
            EKG.parameter2 = obj.opts.parameter2;

            if ~isempty(obj.opts.rriPeaksIdxInit) || ~isempty(obj.opts.rriInvalidIdxInit)
                EKG.rriCustomActive = true;
                if ~isempty(obj.opts.rriPeaksIdxInit)
                    EKG.rriPeaksIdx = obj.sanitizePeaks(obj.opts.rriPeaksIdxInit, numel(obj.ecg));
                else
                    EKG.rriPeaksIdx = obj.peaksIdx(:);
                end
                if ~isempty(obj.opts.rriInvalidIdxInit)
                    EKG.rriInvalidIdx = obj.sanitizePeaks(obj.opts.rriInvalidIdxInit, numel(obj.ecg));
                else
                    EKG.rriInvalidIdx = zeros(0,1);
                end
            end

            capSampleIdx = obj.sanitizePeaks(obj.opts.rriCapSampleIdxInit, numel(obj.ecg));
            capValuesMs = double(obj.opts.rriCapValuesMsInit(:));
            if isempty(capSampleIdx) || isempty(capValuesMs)
                capSampleIdx = zeros(0,1);
                capValuesMs = zeros(0,1);
            else
                if isscalar(capValuesMs) && numel(capSampleIdx) > 1
                    capValuesMs = repmat(capValuesMs, numel(capSampleIdx), 1);
                end
                nCap = min(numel(capSampleIdx), numel(capValuesMs));
                capSampleIdx = capSampleIdx(1:nCap);
                capValuesMs = capValuesMs(1:nCap);
                validCapMask = isfinite(capSampleIdx) & isfinite(capValuesMs);
                capSampleIdx = capSampleIdx(validCapMask);
                capValuesMs = capValuesMs(validCapMask);
                if ~isempty(capSampleIdx)
                    [capSampleIdxStable, ~, groupIdx] = unique(capSampleIdx, 'stable');
                    capValuesStable = zeros(numel(capSampleIdxStable), 1);
                    for i = 1:numel(capSampleIdxStable)
                        capValuesStable(i) = capValuesMs(find(groupIdx == i, 1, 'last')); %#ok<FNDSB>
                    end
                    capSampleIdx = capSampleIdxStable;
                    capValuesMs = capValuesStable;
                end
            end
            EKG.rriCapSampleIdx = capSampleIdx;
            EKG.rriCapValuesMs = capValuesMs;

            obj.syncGlobalPeaks();
        end

        function syncGlobalPeaks(obj)
            global EKG;
            if isempty(obj.peaksIdx)
                EKG.peaks = [];
                EKG.t_peaks = [];
                EKG.ibis = [];
                EKG.ibi_spline = [];
                EKG.ibi_spline_t = [];
                EKG.indxPeaks = [];
                return
            end

            EKG.peaks = [obj.peaksIdx(:) obj.peaksAmp(:)];
            EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;
            EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime);
            if ~isfield(EKG, 'rriCustomActive') || ~EKG.rriCustomActive
                EKG.rriPeaksIdx = EKG.peaks(:,1);
            end
            if numel(EKG.t_peaks) < 2
                EKG.ibis = [];
                EKG.ibi_spline = [];
                EKG.ibi_spline_t = [];
                return
            end
            EKG.time_second_peak = EKG.t_peaks(2);
            EKG.ibis = 1000*diff(EKG.t_peaks);
            y = EKG.ibis;
            x = EKG.t_peaks(2:end);
            t = (x-x(1));
            tMax = round(t(end));
            xx = 0:0.1:tMax;
            yy = spline(t, y, xx);
            EKG.ibi_spline = yy;
            EKG.ibi_spline_t = xx + x(1);
        end

        function syncUiAfterEdit(obj)
            if ~obj.uiActive
                return
            end
            obj.syncGlobalPeaks();
            if ~isempty(obj.ui)
                obj.ui.drawIbiPlot();
                obj.ui.drawPsdPlot();
                obj.ui.drawEkgPlot();
            end
        end

        function refreshRriForCurrentWindow(obj)
            global EKG;
            if isempty(EKG) || ~isstruct(EKG) || ~isfield(EKG, 'plot') || ...
                    ~isfield(EKG, 'sampRate') || isempty(obj.peaksIdx)
                obj.resetRriToEcg();
                return
            end

            nSamples = numel(obj.ecg);
            windowStart = max(1, floor(EKG.plot.startTime * EKG.sampRate) + 1);
            windowEnd = min(nSamples, ceil(EKG.plot.endTime * EKG.sampRate));
            if windowEnd < windowStart
                windowEnd = windowStart;
            end

            currentPeaks = obj.sanitizePeaks(obj.peaksIdx, nSamples);
            if isfield(EKG, 'rriCustomActive') && EKG.rriCustomActive && ...
                    isfield(EKG, 'rriPeaksIdx') && ~isempty(EKG.rriPeaksIdx)
                baseRriPeaks = obj.sanitizePeaks(EKG.rriPeaksIdx, nSamples);
            else
                baseRriPeaks = currentPeaks;
            end

            outsideMask = baseRriPeaks < windowStart | baseRriPeaks > windowEnd;
            insideCurrent = currentPeaks(currentPeaks >= windowStart & currentPeaks <= windowEnd);
            rriPeaksIdx = obj.sanitizePeaks([baseRriPeaks(outsideMask); insideCurrent(:)], nSamples);

            invalidIdx = zeros(0,1);
            if isfield(EKG, 'rriInvalidIdx') && ~isempty(EKG.rriInvalidIdx)
                invalidIdx = obj.sanitizePeaks(EKG.rriInvalidIdx, nSamples);
                invalidIdx = invalidIdx(invalidIdx < windowStart | invalidIdx > windowEnd);
            end
            invalidIdx = ECGManualInspector.sanitizeInvalidRriIdx(invalidIdx, rriPeaksIdx);

            EKG.rriCustomActive = true;
            EKG.rriPeaksIdx = rriPeaksIdx;
            EKG.rriInvalidIdx = invalidIdx;
            if ~isfield(EKG, 'rriCapSampleIdx') || isempty(EKG.rriCapSampleIdx)
                EKG.rriCapSampleIdx = zeros(0,1);
            end
            if ~isfield(EKG, 'rriCapValuesMs') || isempty(EKG.rriCapValuesMs)
                EKG.rriCapValuesMs = zeros(0,1);
            end
        end

        function resetRriToEcg(~)
            global EKG;
            EKG.rriCustomActive = false;
            EKG.rriPeaksIdx = [];
            EKG.rriInvalidIdx = [];
            EKG.rriCapSampleIdx = zeros(0,1);
            EKG.rriCapValuesMs = zeros(0,1);
        end

        function timestamps = sanitizeEcgTimestamps(~, timestampsIn, nSamples)
            timestamps = [];
            if isempty(timestampsIn)
                return
            end
            if istable(timestampsIn)
                if ismember('Timestamp', timestampsIn.Properties.VariableNames)
                    timestampsIn = timestampsIn.Timestamp;
                else
                    return
                end
            end
            timestampsIn = timestampsIn(:);
            if numel(timestampsIn) ~= nSamples
                return
            end
            timestamps = timestampsIn;
        end

        function peakTimes = resolvePeakTimeText(obj, peakIdx)
            if isempty(peakIdx)
                peakTimes = strings(0,1);
                return
            end

            peakIdx = double(peakIdx(:));
            peakTimes = repmat("", numel(peakIdx), 1);
            validMask = isfinite(peakIdx);
            if ~any(validMask)
                return
            end

            peakIdxRounded = round(peakIdx(validMask));
            outRows = find(validMask);
            if ~isempty(obj.fs) && isfinite(obj.fs) && obj.fs > 0
                peakTimes(outRows) = string(seconds((peakIdxRounded - 1) ./ obj.fs));
            end
        end

        function figHandles = collectFigureHandles(~)
            figHandles = struct();
            figHandles.ekgPlot = findobj('Tag', 'FigureEkgPlot');
            figHandles.ekgControl = findobj('Tag', 'FigureEkgControl');
            figHandles.ibiPlot = findobj('Tag', 'FigureIbiPlot');
            figHandles.psdPlot = findobj('Tag', 'FigurePsdPlot');
        end

        function figHandles = pruneFigureHandles(~, figHandles)
            fields = fieldnames(figHandles);
            for i = 1:numel(fields)
                f = fields{i};
                if isempty(figHandles.(f)) || ~ishandle(figHandles.(f))
                    figHandles.(f) = [];
                end
            end
        end
    end

    methods (Static)
        function value = getStructField(source, fieldName, defaultValue)
            if isstruct(source) && isfield(source, fieldName)
                value = source.(fieldName);
            else
                value = defaultValue;
            end
        end

        function invalidIdx = sanitizeInvalidRriIdx(invalidIdx, rriPeaksIdx)
            if isempty(invalidIdx) || isempty(rriPeaksIdx) || numel(rriPeaksIdx) < 2
                invalidIdx = zeros(0,1);
                return
            end
            invalidIdx = double(invalidIdx(:));
            invalidIdx = invalidIdx(isfinite(invalidIdx));
            invalidIdx = round(invalidIdx);
            validIbiPeaks = double(rriPeaksIdx(2:end));
            invalidIdx = invalidIdx(ismember(invalidIdx, validIbiPeaks));
            invalidIdx = unique(invalidIdx, 'stable');
        end

        function editLog = initEditLogTable()
            editLog = table('Size', [0 10], ...
                'VariableTypes', {'datetime','string','double','double','string','string','string','string','string','string'}, ...
                'VariableNames', {'timestamp','action','peak_before','peak_after','peakTime_before','peakTime_after','note','userId','sessionId','editTarget'});
        end

        function rows = buildEditLogRows(action, peakBefore, peakAfter, note, userId, sessionId, timestamp, peakTimeBefore, peakTimeAfter, editTarget)
            if nargin < 7 || isempty(timestamp)
                timestamp = datetime('now');
            end
            if nargin < 8 || isempty(peakTimeBefore)
                peakTimeBefore = repmat("", numel(peakBefore), 1);
            end
            if nargin < 9 || isempty(peakTimeAfter)
                peakTimeAfter = repmat("", numel(peakAfter), 1);
            end
            if nargin < 10 || isempty(editTarget)
                editTarget = ECGManualInspector.defaultEditTargetFromActionNote(action, note);
            end
            action = string(action);
            peakBefore = double(peakBefore);
            peakAfter = double(peakAfter);
            peakTimeBefore = string(peakTimeBefore);
            peakTimeAfter = string(peakTimeAfter);
            note = string(note);
            userId = string(userId);
            sessionId = string(sessionId);
            editTarget = string(editTarget);
            nRows = max([numel(timestamp), numel(action), numel(peakBefore), ...
                numel(peakAfter), numel(peakTimeBefore), numel(peakTimeAfter), ...
                numel(note), numel(userId), numel(sessionId), numel(editTarget)]);
            timestamp = ECGManualInspector.expandToRows(timestamp, nRows);
            action = ECGManualInspector.expandToRows(action, nRows);
            peakBefore = ECGManualInspector.expandToRows(peakBefore, nRows);
            peakAfter = ECGManualInspector.expandToRows(peakAfter, nRows);
            peakTimeBefore = ECGManualInspector.expandToRows(peakTimeBefore, nRows);
            peakTimeAfter = ECGManualInspector.expandToRows(peakTimeAfter, nRows);
            note = ECGManualInspector.expandToRows(note, nRows);
            userId = ECGManualInspector.expandToRows(userId, nRows);
            sessionId = ECGManualInspector.expandToRows(sessionId, nRows);
            editTarget = ECGManualInspector.expandToRows(editTarget, nRows);
            rows = table(timestamp, action, peakBefore, peakAfter, ...
                peakTimeBefore, peakTimeAfter, ...
                note, userId, sessionId, editTarget, 'VariableNames', ...
                {'timestamp','action','peak_before','peak_after','peakTime_before','peakTime_after','note','userId','sessionId','editTarget'});
        end

        function value = expandToRows(value, nRows)
            value = value(:);
            if nRows > 1 && isscalar(value)
                value = repmat(value, nRows, 1);
            end
        end

        function editLog = normalizeEditLogTable(editLog)
            template = ECGManualInspector.initEditLogTable();
            if ~istable(editLog)
                editLog = template;
                return
            end

            nRows = height(editLog);
            vars = template.Properties.VariableNames;
            if ~ismember('timestamp', editLog.Properties.VariableNames)
                editLog.timestamp = repmat(NaT, nRows, 1);
            end
            if ~ismember('action', editLog.Properties.VariableNames)
                editLog.action = repmat("", nRows, 1);
            end
            if ~ismember('peak_before', editLog.Properties.VariableNames)
                editLog.peak_before = nan(nRows, 1);
            end
            if ~ismember('peak_after', editLog.Properties.VariableNames)
                editLog.peak_after = nan(nRows, 1);
            end
            if ~ismember('peakTime_before', editLog.Properties.VariableNames)
                editLog.peakTime_before = repmat("", nRows, 1);
            end
            if ~ismember('peakTime_after', editLog.Properties.VariableNames)
                editLog.peakTime_after = repmat("", nRows, 1);
            end
            if ~ismember('note', editLog.Properties.VariableNames)
                editLog.note = repmat("", nRows, 1);
            end
            if ~ismember('userId', editLog.Properties.VariableNames)
                editLog.userId = repmat("", nRows, 1);
            end
            if ~ismember('sessionId', editLog.Properties.VariableNames)
                editLog.sessionId = repmat("", nRows, 1);
            end
            if ~ismember('editTarget', editLog.Properties.VariableNames)
                editLog.editTarget = ECGManualInspector.defaultEditTargetFromActionNote(editLog.action, editLog.note);
            end

            if ~isdatetime(editLog.timestamp)
                try
                    editLog.timestamp = datetime(editLog.timestamp);
                catch
                    editLog.timestamp = repmat(NaT, nRows, 1);
                end
            end

            stringVars = {'action','peakTime_before','peakTime_after','note','userId','sessionId','editTarget'};
            for i = 1:numel(stringVars)
                v = stringVars{i};
                editLog.(v) = string(editLog.(v));
            end
            editLog.peak_before = ECGManualInspector.coerceNumericColumn(editLog.peak_before);
            editLog.peak_after = ECGManualInspector.coerceNumericColumn(editLog.peak_after);
            editLog = editLog(:, vars);
        end

        function editTarget = defaultEditTargetFromActionNote(action, note)
            action = lower(strtrim(string(action)));
            note = lower(strtrim(string(note)));
            nRows = max(numel(action), numel(note));
            action = ECGManualInspector.expandToRows(action, nRows);
            note = ECGManualInspector.expandToRows(note, nRows);
            editTarget = repmat("ecg_peak", nRows, 1);

            isRriNote = startsWith(note, "ui_rri_");
            isAutoNote = startsWith(note, "auto_");
            deleteMask = action == "delete";

            editTarget(isRriNote & ~deleteMask) = "rri_peak";
            editTarget(isRriNote & deleteMask) = "rri_invalid";
            editTarget(isAutoNote & ~deleteMask) = "rri_peak";
            editTarget(isAutoNote & deleteMask) = "rri_invalid";
            editTarget(action == "cap") = "rri_peak";
        end

        function numericColumn = coerceNumericColumn(columnIn)
            if isnumeric(columnIn)
                numericColumn = double(columnIn);
            else
                numericColumn = str2double(string(columnIn));
            end
            numericColumn = numericColumn(:);
        end

        function opts = applyDefaultOpts(opts)
            defaults.launchUI = true;
            defaults.computeIfEmpty = true;
            defaults.userId = "";
            defaults.sessionId = "manualReviewECGPeaks_" + string(datestr(now, 'yyyymmdd_HHMMSS'));
            defaults.returnFigures = true;
            defaults.verbose = true;
            defaults.dataSource = "memory";
            defaults.parameter1 = [];
            defaults.parameter2 = [];
            defaults.resume = false;
            defaults.peaksRawIdxOverride = [];
            defaults.peaksReviewedIdxInit = [];
            defaults.editLogsInit = table();
            defaults.reviewLogInit = table();
            defaults.flaggedWindows = [];
            defaults.rriPeaksIdxInit = [];
            defaults.rriInvalidIdxInit = [];
            defaults.rriCapSampleIdxInit = [];
            defaults.rriCapValuesMsInit = [];
            defaults.ecgTimestamps = [];

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
    end
end
