classdef ECGRriReviewStateManager < handle
    properties (Access=private)
        rriReviewed
        rriPeaksReviewedIdx
        rriInvalidReviewedIdx
    end

    methods
        function obj = ECGRriReviewStateManager()
            obj.reset();
        end

        function reset(obj)
            obj.rriReviewed = table();
            obj.rriPeaksReviewedIdx = zeros(0,1);
            obj.rriInvalidReviewedIdx = zeros(0,1);
        end

        function setReviewedRri(obj, rriReviewed)
            if istable(rriReviewed) && ...
                    all(ismember({'Timestamp','RRI'}, rriReviewed.Properties.VariableNames))
                obj.rriReviewed = rriReviewed(:, {'Timestamp','RRI'});
            else
                obj.rriReviewed = table();
            end
        end

        function rriReviewed = getReviewedRri(obj, fallbackRri)
            if istable(obj.rriReviewed) && ...
                    all(ismember({'Timestamp','RRI'}, obj.rriReviewed.Properties.VariableNames))
                rriReviewed = obj.rriReviewed(:, {'Timestamp','RRI'});
                return
            end
            if istable(fallbackRri) && ...
                    all(ismember({'Timestamp','RRI'}, fallbackRri.Properties.VariableNames))
                rriReviewed = fallbackRri(:, {'Timestamp','RRI'});
                return
            end
            rriReviewed = table();
        end

        function ensureScaffold(obj, rriCurrent, peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples)
            if isempty(obj.rriPeaksReviewedIdx)
                if ~isempty(peaksReviewedIdx)
                    obj.rriPeaksReviewedIdx = ECGRriReviewStateManager.sanitizeSampleIndices(peaksReviewedIdx, nSamples);
                elseif ~isempty(peaksRawIdx)
                    obj.rriPeaksReviewedIdx = ECGRriReviewStateManager.sanitizeSampleIndices(peaksRawIdx, nSamples);
                else
                    obj.rriPeaksReviewedIdx = ECGRriReviewStateManager.sanitizeSampleIndices(fallbackPeaks, nSamples);
                end
            else
                obj.rriPeaksReviewedIdx = ECGRriReviewStateManager.sanitizeSampleIndices(obj.rriPeaksReviewedIdx, nSamples);
            end

            if isempty(obj.rriInvalidReviewedIdx)
                obj.rriInvalidReviewedIdx = zeros(0,1);
            else
                obj.rriInvalidReviewedIdx = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                    obj.rriInvalidReviewedIdx, obj.rriPeaksReviewedIdx, nSamples);
            end

            if (isempty(obj.rriReviewed) || ~istable(obj.rriReviewed)) && ~isempty(rriCurrent)
                obj.setReviewedRri(rriCurrent);
            end
        end

        function [rriPeaksIdx, rriInvalidIdx] = getIndicesForCurrentState(obj, useReviewedState, ...
                peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent)
            if nargin < 2
                useReviewedState = true;
            end

            if useReviewedState
                obj.ensureScaffold(rriCurrent, peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples);
                rriPeaksIdx = obj.rriPeaksReviewedIdx(:);
                rriInvalidIdx = obj.rriInvalidReviewedIdx(:);
            else
                rriPeaksIdx = ECGRriReviewStateManager.sanitizeSampleIndices(peaksRawIdx, nSamples);
                if isempty(rriPeaksIdx)
                    rriPeaksIdx = ECGRriReviewStateManager.sanitizeSampleIndices(fallbackPeaks, nSamples);
                end
                rriInvalidIdx = zeros(0,1);
            end

            rriInvalidIdx = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                rriInvalidIdx, rriPeaksIdx, nSamples);
        end

        function sampleIdx = getRriSampleIdxForCurrentState(obj, rriCount, useReviewedState, ...
                peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent)
            if nargin < 3
                useReviewedState = true;
            end
            if isempty(rriCount) || rriCount < 1
                sampleIdx = zeros(0,1);
                return
            end

            rriCount = round(double(rriCount));
            sampleIdx = (1:rriCount).';

            [peaksForRri, invalidIdx] = obj.getIndicesForCurrentState(useReviewedState, ...
                peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent);
            if numel(peaksForRri) < 2
                return
            end

            mappedSamples = peaksForRri(2:end);
            if useReviewedState && ~isempty(invalidIdx)
                mappedSamples = mappedSamples(~ismember(mappedSamples, invalidIdx));
            end

            mappedCount = min(rriCount, numel(mappedSamples));
            if mappedCount < rriCount && useReviewedState
                sampleIdx = obj.getRriSampleIdxForCurrentState(rriCount, false, ...
                    peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent);
                return
            end
            if mappedCount > 0
                sampleIdx(1:mappedCount) = mappedSamples(1:mappedCount);
            end
        end

        function invalidIdx = normalizeInvalidForPeaks(~, invalidIdx, rriPeaksIdx, nSamples)
            invalidIdx = ECGRriReviewStateManager.sanitizeInvalidRriIdx(invalidIdx, rriPeaksIdx, nSamples);
        end

        function setReviewedIndices(obj, rriPeaksIdx, rriInvalidIdx, ...
                peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent)
            obj.ensureScaffold(rriCurrent, peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples);
            rriPeaksIdx = ECGRriReviewStateManager.sanitizeSampleIndices(rriPeaksIdx, nSamples);
            if isempty(rriPeaksIdx)
                rriPeaksIdx = obj.rriPeaksReviewedIdx(:);
            end
            obj.rriPeaksReviewedIdx = rriPeaksIdx(:);
            obj.rriInvalidReviewedIdx = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                rriInvalidIdx, obj.rriPeaksReviewedIdx, nSamples);
        end

        function appendInvalidSamples(obj, removedSampleIdx, ...
                peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent)
            obj.ensureScaffold(rriCurrent, peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples);
            removedSampleIdx = ECGRriReviewStateManager.sanitizeSampleIndices(removedSampleIdx, nSamples);
            obj.rriInvalidReviewedIdx = unique([obj.rriInvalidReviewedIdx(:); removedSampleIdx(:)], 'stable');
            obj.rriInvalidReviewedIdx = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                obj.rriInvalidReviewedIdx, obj.rriPeaksReviewedIdx, nSamples);
            obj.setReviewedRri(rriCurrent);
        end

        function [rriPeaksIdx, rriInvalidIdx] = getReviewedIndices(obj, ...
                peaksReviewedIdx, peaksRawIdx, fallbackPeaks, nSamples, rriCurrent)
            obj.ensureScaffold(rriCurrent, peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples);
            rriPeaksIdx = obj.rriPeaksReviewedIdx(:);
            rriInvalidIdx = obj.rriInvalidReviewedIdx(:);
        end

        function [peaksRawIdxOut, peaksReviewedIdxOut, rriCurrentOut] = applyResumeState(obj, resumeData, ...
                peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples, rriCurrent, computeRriFromPeaksFcn)
            peaksRawIdxOut = peaksRawIdx;
            peaksReviewedIdxOut = peaksReviewedIdx;
            rriCurrentOut = rriCurrent;

            peaksRaw = ECGRriReviewStateManager.sanitizeSampleIndices(resumeData.peaksRawIdx, nSamples);
            if isempty(peaksRawIdxOut) && ~isempty(peaksRaw)
                peaksRawIdxOut = peaksRaw;
            end

            peaksReviewed = ECGRriReviewStateManager.sanitizeSampleIndices(resumeData.peaksReviewedIdx, nSamples);
            if ~isempty(peaksReviewed)
                peaksReviewedIdxOut = peaksReviewed;
            end

            rriPeaks = ECGRriReviewStateManager.sanitizeSampleIndices(resumeData.rriPeaksIdx, nSamples);
            if isempty(rriPeaks)
                if ~isempty(peaksReviewed)
                    rriPeaks = peaksReviewed;
                elseif ~isempty(peaksRaw)
                    rriPeaks = peaksRaw;
                else
                    rriPeaks = ECGRriReviewStateManager.sanitizeSampleIndices(fallbackPeaks, nSamples);
                end
            end

            rriInvalid = ECGRriReviewStateManager.sanitizeInvalidRriIdx(resumeData.rriInvalidIdx, rriPeaks, nSamples);

            rriReviewed = computeRriFromPeaksFcn(rriPeaks);
            if ~isempty(rriReviewed) && ~isempty(rriInvalid) && numel(rriPeaks) >= 2
                invalidMask = ismember(rriPeaks(2:end), rriInvalid);
                rriReviewed = rriReviewed(~invalidMask, :);
            end

            if istable(rriReviewed)
                obj.setReviewedRri(rriReviewed);
                rriCurrentOut = rriReviewed;
            end

            obj.rriPeaksReviewedIdx = rriPeaks(:);
            obj.rriInvalidReviewedIdx = rriInvalid(:);

            if isempty(peaksReviewedIdxOut) && ~isempty(rriPeaks)
                peaksReviewedIdxOut = rriPeaks(:);
            end
        end

        function rriCurrentOut = applyManualReviewResult(obj, rriPeaksIdx, rriInvalidIdx, ...
                peaksReviewedIdx, peaksRawIdx, fallbackPeaks, nSamples, rriCurrent, computeRriFromPeaksFcn)
            obj.ensureScaffold(rriCurrent, peaksRawIdx, peaksReviewedIdx, fallbackPeaks, nSamples);

            if ~isempty(rriPeaksIdx)
                rriPeaks = ECGRriReviewStateManager.sanitizeSampleIndices(rriPeaksIdx, nSamples);
                rriInvalid = ECGRriReviewStateManager.sanitizeInvalidRriIdx(rriInvalidIdx, rriPeaks, nSamples);
                rriReviewed = computeRriFromPeaksFcn(rriPeaks);
                if ~isempty(rriInvalid) && ~isempty(rriReviewed)
                    invalidMask = ismember(rriPeaks(2:end), rriInvalid);
                    rriReviewed = rriReviewed(~invalidMask, :);
                end
                obj.rriPeaksReviewedIdx = rriPeaks(:);
                obj.rriInvalidReviewedIdx = rriInvalid(:);
            else
                rriPeaks = ECGRriReviewStateManager.sanitizeSampleIndices(peaksReviewedIdx, nSamples);
                if isempty(rriPeaks)
                    rriPeaks = obj.rriPeaksReviewedIdx(:);
                end
                rriInvalid = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                    obj.rriInvalidReviewedIdx, rriPeaks, nSamples);
                rriReviewed = computeRriFromPeaksFcn(rriPeaks);
                if ~isempty(rriInvalid) && ~isempty(rriReviewed) && numel(rriPeaks) >= 2
                    invalidMask = ismember(rriPeaks(2:end), rriInvalid);
                    rriReviewed = rriReviewed(~invalidMask, :);
                end
                obj.rriPeaksReviewedIdx = rriPeaks(:);
                obj.rriInvalidReviewedIdx = rriInvalid(:);
            end

            obj.setReviewedRri(rriReviewed);
            rriCurrentOut = obj.getReviewedRri(rriCurrent);
        end

    end

    methods (Static)
        function [ok, resumeData] = loadResumeState(qcDir, nSamples, peaksRawIdxBase)
            if nargin < 3
                peaksRawIdxBase = [];
            end

            ok = false;
            resumeData = struct('peaksRawIdx', [], 'peaksReviewedIdx', [], ...
                'editLogs', table(), 'reviewLog', table(), ...
                'flaggedWindows', [], 'rriPeaksIdx', [], 'rriInvalidIdx', []);
            resumeData.peaksRawIdx = ECGRriReviewStateManager.sanitizeSampleIndices(peaksRawIdxBase, nSamples);

            editLogCsvFile = fullfile(qcDir, 'edit_logs.csv');
            if exist(editLogCsvFile, 'file') == 2
                resumeData.editLogs = readtable(editLogCsvFile, 'TextType', 'string');
            end

            reviewLogFile = fullfile(qcDir, 'review_log.mat');
            if exist(reviewLogFile, 'file') == 2
                reviewLogData = load(reviewLogFile);
                if isfield(reviewLogData, 'reviewLog')
                    resumeData.reviewLog = reviewLogData.reviewLog;
                end
            end

            flaggedWindowsFile = fullfile(qcDir, 'flagged_windows.mat');
            if exist(flaggedWindowsFile, 'file') == 2
                flaggedData = load(flaggedWindowsFile);
                if isfield(flaggedData, 'flaggedWindows')
                    resumeData.flaggedWindows = flaggedData.flaggedWindows;
                end
            end

            resumeData.editLogs = ECGManualInspector.normalizeEditLogTable(resumeData.editLogs);

            [resumeData.peaksReviewedIdx, resumeData.rriPeaksIdx, resumeData.rriInvalidIdx] = ...
                ECGRriReviewStateManager.rebuildStateFromEditLogs( ...
                resumeData.editLogs, resumeData.peaksRawIdx, nSamples);

            hasLogs = istable(resumeData.editLogs) && ~isempty(resumeData.editLogs);
            hasReviewLog = istable(resumeData.reviewLog) && ~isempty(resumeData.reviewLog);
            hasFlaggedWindows = ~isempty(resumeData.flaggedWindows);
            if ~(hasLogs || hasReviewLog || hasFlaggedWindows)
                return
            end

            if ~isempty(nSamples) && ~isempty(resumeData.peaksRawIdx)
                if any(resumeData.peaksRawIdx < 1 | resumeData.peaksRawIdx > nSamples)
                    warning('ECG:ManualInspectionSampleMismatch', ...
                        'QC bundle peak indices exceed current ECG length.');
                end
            end

            if isempty(resumeData.peaksReviewedIdx)
                resumeData.peaksReviewedIdx = resumeData.peaksRawIdx;
            end
            if isempty(resumeData.rriPeaksIdx)
                resumeData.rriPeaksIdx = resumeData.peaksReviewedIdx;
            end
            if isempty(resumeData.rriInvalidIdx)
                resumeData.rriInvalidIdx = zeros(0,1);
            end

            ok = true;
        end

        function nSamples = resolveSampleCount(sourceECG, data, peaksRawIdx)
            nSamples = [];
            if ~isempty(sourceECG)
                if istable(sourceECG) || istimetable(sourceECG)
                    nSamples = height(sourceECG);
                    return
                end
                if isobject(sourceECG) && isprop(sourceECG, 'data') && ~isempty(sourceECG.data)
                    if istable(sourceECG.data) || istimetable(sourceECG.data)
                        nSamples = height(sourceECG.data);
                    else
                        nSamples = numel(sourceECG.data);
                    end
                    return
                end
                if isnumeric(sourceECG) || islogical(sourceECG) || isduration(sourceECG) || isdatetime(sourceECG)
                    nSamples = numel(sourceECG);
                    return
                end
            end
            if ~isempty(data)
                if istable(data) || istimetable(data)
                    nSamples = height(data);
                else
                    nSamples = numel(data);
                end
                return
            end
            if ~isempty(peaksRawIdx)
                peaksRawIdx = double(peaksRawIdx(:));
                peaksRawIdx = peaksRawIdx(isfinite(peaksRawIdx));
                if ~isempty(peaksRawIdx)
                    nSamples = max(round(peaksRawIdx));
                end
            end
        end
    end

    methods (Static, Access=private)
        function [peaksReviewedIdx, rriPeaksIdx, rriInvalidIdx] = rebuildStateFromEditLogs(editLogs, peaksRawIdx, nSamples)
            peaksReviewedIdx = ECGRriReviewStateManager.sanitizeSampleIndices(peaksRawIdx, nSamples);
            rriPeaksIdx = peaksReviewedIdx;
            rriInvalidIdx = zeros(0,1);

            if ~istable(editLogs) || isempty(editLogs)
                return
            end

            editLogs = ECGManualInspector.normalizeEditLogTable(editLogs);
            nRows = height(editLogs);
            for i = 1:nRows
                action = lower(strtrim(string(editLogs.action(i))));
                target = lower(strtrim(string(editLogs.editTarget(i))));
                if strlength(target) == 0
                    target = lower(strtrim(string( ...
                        ECGManualInspector.defaultEditTargetFromActionNote(editLogs.action(i), editLogs.note(i)))));
                end
                peakBefore = ECGRriReviewStateManager.parseSampleValue(editLogs.peak_before(i), nSamples);
                peakAfter = ECGRriReviewStateManager.parseSampleValue(editLogs.peak_after(i), nSamples);

                switch target
                    case "ecg_peak"
                        peaksReviewedIdx = ECGRriReviewStateManager.applyPeakAction( ...
                            peaksReviewedIdx, action, peakBefore, peakAfter, nSamples);
                        if any(action == ["insert","delete","move"])
                            rriPeaksIdx = peaksReviewedIdx;
                            rriInvalidIdx = ECGRriReviewStateManager.remapInvalidAfterPeakAction( ...
                                rriInvalidIdx, action, peakBefore, peakAfter, rriPeaksIdx, nSamples);
                        end

                    case "rri_peak"
                        rriPeaksIdx = ECGRriReviewStateManager.applyPeakAction( ...
                            rriPeaksIdx, action, peakBefore, peakAfter, nSamples);
                        rriInvalidIdx = ECGRriReviewStateManager.remapInvalidAfterPeakAction( ...
                            rriInvalidIdx, action, peakBefore, peakAfter, rriPeaksIdx, nSamples);

                    case "rri_invalid"
                        rriInvalidIdx = ECGRriReviewStateManager.applyInvalidAction( ...
                            rriInvalidIdx, action, peakBefore, peakAfter, rriPeaksIdx, nSamples);
                end

                rriPeaksIdx = ECGRriReviewStateManager.sanitizeSampleIndices(rriPeaksIdx, nSamples);
                rriInvalidIdx = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                    rriInvalidIdx, rriPeaksIdx, nSamples);
            end
        end

        function peaksOut = applyPeakAction(peaksIn, action, peakBefore, peakAfter, nSamples)
            peaksOut = ECGRriReviewStateManager.sanitizeSampleIndices(peaksIn, nSamples);
            action = lower(strtrim(string(action)));

            switch action
                case "insert"
                    sampleToAdd = peakAfter;
                    if ~isfinite(sampleToAdd)
                        sampleToAdd = peakBefore;
                    end
                    if isfinite(sampleToAdd)
                        peaksOut = ECGRriReviewStateManager.sanitizeSampleIndices( ...
                            [peaksOut(:); sampleToAdd], nSamples);
                    end

                case "delete"
                    sampleToDelete = peakBefore;
                    if ~isfinite(sampleToDelete)
                        sampleToDelete = peakAfter;
                    end
                    if isfinite(sampleToDelete)
                        peaksOut = peaksOut(peaksOut ~= sampleToDelete);
                    end

                case "move"
                    sampleFrom = peakBefore;
                    sampleTo = peakAfter;
                    if isfinite(sampleFrom)
                        peaksOut = peaksOut(peaksOut ~= sampleFrom);
                    end
                    if isfinite(sampleTo)
                        peaksOut = ECGRriReviewStateManager.sanitizeSampleIndices( ...
                            [peaksOut(:); sampleTo], nSamples);
                    end
            end
        end

        function invalidOut = applyInvalidAction(invalidIn, action, peakBefore, peakAfter, rriPeaksIdx, nSamples)
            invalidOut = ECGRriReviewStateManager.sanitizeSampleIndices(invalidIn, nSamples);
            action = lower(strtrim(string(action)));

            switch action
                case "delete"
                    sampleToMark = peakBefore;
                    if ~isfinite(sampleToMark)
                        sampleToMark = peakAfter;
                    end
                    if isfinite(sampleToMark)
                        invalidOut = unique([invalidOut(:); sampleToMark], 'stable');
                    end

                case "insert"
                    sampleToRestore = peakAfter;
                    if ~isfinite(sampleToRestore)
                        sampleToRestore = peakBefore;
                    end
                    if isfinite(sampleToRestore)
                        invalidOut = invalidOut(invalidOut ~= sampleToRestore);
                    end

                case "move"
                    sampleFrom = peakBefore;
                    sampleTo = peakAfter;
                    if isfinite(sampleFrom)
                        invalidOut(invalidOut == sampleFrom) = [];
                    end
                    if isfinite(sampleTo)
                        invalidOut = unique([invalidOut(:); sampleTo], 'stable');
                    end
            end

            invalidOut = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                invalidOut, rriPeaksIdx, nSamples);
        end

        function invalidOut = remapInvalidAfterPeakAction(invalidIn, action, peakBefore, peakAfter, rriPeaksIdx, nSamples)
            % Keep existing invalid labels through peak edits, only remapping
            % labels that target a moved/deleted peak sample.
            invalidOut = ECGRriReviewStateManager.sanitizeSampleIndices(invalidIn, nSamples);
            action = lower(strtrim(string(action)));

            switch action
                case "move"
                    if isfinite(peakBefore) && isfinite(peakAfter) && ~isempty(invalidOut)
                        invalidOut(invalidOut == peakBefore) = peakAfter;
                    end

                case "delete"
                    if isfinite(peakBefore)
                        invalidOut(invalidOut == peakBefore) = [];
                    end
            end

            invalidOut = ECGRriReviewStateManager.sanitizeInvalidRriIdx( ...
                invalidOut, rriPeaksIdx, nSamples);
        end

        function sample = parseSampleValue(valueIn, nSamples)
            sample = nan;
            if isempty(valueIn)
                return
            end

            sampleCandidate = double(valueIn(1));
            if ~isfinite(sampleCandidate)
                return
            end

            sampleCandidate = round(sampleCandidate);
            if ~isempty(nSamples) && isfinite(nSamples) && nSamples > 0
                if sampleCandidate < 1 || sampleCandidate > nSamples
                    return
                end
            else
                if sampleCandidate < 1
                    return
                end
            end

            sample = sampleCandidate;
        end

        function sampleIdx = sanitizeSampleIndices(sampleIdx, nSamples)
            if isempty(sampleIdx)
                sampleIdx = zeros(0,1);
                return
            end

            sampleIdx = double(sampleIdx(:));
            sampleIdx = sampleIdx(isfinite(sampleIdx));
            sampleIdx = round(sampleIdx);
            if ~isempty(nSamples) && isfinite(nSamples) && nSamples > 0
                sampleIdx = sampleIdx(sampleIdx >= 1 & sampleIdx <= nSamples);
            else
                sampleIdx = sampleIdx(sampleIdx >= 1);
            end
            sampleIdx = unique(sampleIdx);
        end

        function invalidIdx = sanitizeInvalidRriIdx(invalidIdx, rriPeaksIdx, nSamples)
            rriPeaksIdx = ECGRriReviewStateManager.sanitizeSampleIndices(rriPeaksIdx, nSamples);
            if isempty(invalidIdx) || numel(rriPeaksIdx) < 2
                invalidIdx = zeros(0,1);
                return
            end

            invalidIdx = ECGRriReviewStateManager.sanitizeSampleIndices(invalidIdx, nSamples);
            validIbiPeaks = rriPeaksIdx(2:end);
            invalidIdx = invalidIdx(ismember(invalidIdx, validIbiPeaks));
            invalidIdx = unique(invalidIdx, 'stable');
        end
    end
end
