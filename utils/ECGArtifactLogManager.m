classdef ECGArtifactLogManager < handle
    properties (Access=private)
        autoEditLog
    end

    methods
        function obj = ECGArtifactLogManager()
            obj.resetAutoLogs();
        end

        function resetAutoLogs(obj)
            obj.autoEditLog = ECGArtifactLogManager.initEditLogTable();
        end

        function [userId, sessionId] = createAutoReviewIdentity(~, method)
            if nargin < 2 || strlength(method) == 0
                method = "auto";
            end
            userId = string(getenv('USERNAME'));
            if strlength(userId) == 0
                userId = string(getenv('USER'));
            end
            if strlength(userId) == 0
                userId = "";
            end
            sessionId = "auto_ecg_" + string(method) + "_" + string(char(java.util.UUID.randomUUID));
        end

        function appendAutoRriEdits(obj, sampleIdx, action, note, userId, sessionId, peakTimes, fs)
            if nargin < 7
                peakTimes = [];
            end
            if nargin < 8
                fs = [];
            end
            obj.autoEditLog = ECGArtifactLogManager.appendAutoRriEditsToTable( ...
                obj.autoEditLog, sampleIdx, action, note, userId, sessionId, peakTimes, fs);
        end

        function saveReviewLogsAt(obj, qcDir, manualEditLog)
            if nargin < 3
                manualEditLog = table();
            end

            qcDir = string(qcDir);
            if strlength(qcDir) == 0
                return
            end
            qcDir = char(qcDir);
            if ~exist(qcDir, 'dir')
                mkdir(qcDir);
            end

            newEditLogs = obj.mergeManualAndAutoLogs(manualEditLog);
            existingEditLogs = ECGArtifactLogManager.loadExistingReviewLogs(qcDir);
            editLogs = ECGArtifactLogManager.mergePersistedReviewLogs( ...
                existingEditLogs, newEditLogs);

            if istable(editLogs)
                writetable(editLogs, fullfile(qcDir, 'edit_logs.csv'));
                % editOps = ECGArtifactLogManager.buildEditOpsTable(editLogs);
                % writetable(editOps, fullfile(qcDir, 'edit_ops.csv'));
            end
        end
    end

    methods (Access=private)
        function editLogOut = mergeManualAndAutoLogs(obj, manualEditLog)
            editLogOut = ECGManualInspector.normalizeEditLogTable(manualEditLog);
            autoEditLog = ECGManualInspector.normalizeEditLogTable(obj.autoEditLog);

            if istable(autoEditLog) && ~isempty(autoEditLog)
                if isempty(editLogOut)
                    editLogOut = autoEditLog;
                else
                    editLogOut = [editLogOut; autoEditLog];
                    if ismember('timestamp', editLogOut.Properties.VariableNames)
                        editLogOut = sortrows(editLogOut, 'timestamp');
                    end
                end
            end

            editLogOut = ECGManualInspector.normalizeEditLogTable(editLogOut);
        end
    end

    methods (Static, Access=private)
        function editLog = initEditLogTable()
            editLog = ECGManualInspector.initEditLogTable();
        end

        function editLog = appendAutoRriEditsToTable(editLog, sampleIdx, action, note, userId, sessionId, peakTimes, fs)
            if isempty(sampleIdx)
                return
            end

            sampleIdx = double(sampleIdx(:));
            nRows = numel(sampleIdx);
            action = string(action);
            note = string(note);
            userId = string(userId);
            sessionId = string(sessionId);
            timestamp = repmat(datetime('now'), nRows, 1);
            actionVec = repmat(action, nRows, 1);
            if action == "delete"
                editTargetVec = repmat("rri_invalid", nRows, 1);
            else
                editTargetVec = repmat("rri_peak", nRows, 1);
            end
            noteVec = repmat(note, nRows, 1);
            userIdVec = repmat(userId, nRows, 1);
            sessionIdVec = repmat(sessionId, nRows, 1);
            if nargin < 7
                peakTimes = [];
            end
            if nargin < 8
                fs = [];
            end
            defaultPeakTimes = ECGArtifactLogManager.buildSecondsPeakTimes(sampleIdx, fs);
            if nargin < 7 || isempty(peakTimes)
                peakTimes = defaultPeakTimes;
            else
                peakTimes = string(peakTimes(:));
                if isscalar(peakTimes) && nRows > 1
                    peakTimes = repmat(peakTimes, nRows, 1);
                elseif numel(peakTimes) ~= nRows
                    peakTimes = defaultPeakTimes;
                end
                if numel(defaultPeakTimes) == nRows
                    missingMask = peakTimes == "";
                    if any(missingMask)
                        peakTimes(missingMask) = defaultPeakTimes(missingMask);
                    end
                end
            end

            logRows = ECGManualInspector.buildEditLogRows(actionVec, sampleIdx, sampleIdx, ...
                noteVec, userIdVec, sessionIdVec, timestamp, peakTimes, peakTimes, editTargetVec);
            editLog = [editLog; logRows];
        end

        function editLogs = loadExistingReviewLogs(qcDir)
            editLogs = ECGManualInspector.initEditLogTable();

            editLogCsvFile = fullfile(qcDir, 'edit_logs.csv');
            if exist(editLogCsvFile, 'file') == 2
                editLogs = readtable(editLogCsvFile, 'TextType', 'string');
            end

            if ~istable(editLogs)
                editLogs = ECGManualInspector.initEditLogTable();
            end
        end

        function editLogsOut = mergePersistedReviewLogs(existingEditLogs, newEditLogs)
            editLogsOut = ECGArtifactLogManager.mergeEditLogTables(existingEditLogs, newEditLogs);
        end

        function editLogsOut = mergeEditLogTables(existingEditLogs, newEditLogs)
            existingEditLogs = ECGArtifactLogManager.normalizeEditLogTable(existingEditLogs);
            newEditLogs = ECGArtifactLogManager.normalizeEditLogTable(newEditLogs);
            editLogsOut = [existingEditLogs; newEditLogs];
            if isempty(editLogsOut)
                return
            end

            exactKey = string(editLogsOut.timestamp) + "|" + string(editLogsOut.action) + "|" + ...
                string(editLogsOut.peak_before) + "|" + string(editLogsOut.peak_after) + "|" + ...
                string(editLogsOut.peakTime_before) + "|" + string(editLogsOut.peakTime_after) + "|" + ...
                string(editLogsOut.note) + "|" + string(editLogsOut.editTarget) + "|" + string(editLogsOut.userId) + "|" + ...
                string(editLogsOut.sessionId);
            [~, keepExactIdx] = unique(exactKey, 'stable');
            keepMask = false(height(editLogsOut), 1);
            keepMask(keepExactIdx) = true;
            editLogsOut = editLogsOut(keepMask, :);

            noteStr = string(editLogsOut.note);
            autoMask = startsWith(lower(noteStr), "auto_");
            if any(autoMask)
                autoRows = find(autoMask);
                autoKey = string(editLogsOut.action(autoMask)) + "|" + ...
                    string(editLogsOut.peak_before(autoMask)) + "|" + ...
                    string(editLogsOut.peak_after(autoMask)) + "|" + ...
                    string(editLogsOut.editTarget(autoMask)) + "|" + ...
                    noteStr(autoMask);
                [~, ~, autoGroupIdx] = unique(autoKey, 'stable');
                keepAutoRelIdx = zeros(0,1);
                nAutoGroups = max(autoGroupIdx);
                for g = 1:nAutoGroups
                    groupRelRows = find(autoGroupIdx == g);
                    if numel(groupRelRows) == 1
                        keepAutoRelIdx(end+1,1) = groupRelRows; %#ok<AGROW>
                        continue
                    end
                    groupAbsRows = autoRows(groupRelRows);
                    score = strlength(string(editLogsOut.peakTime_before(groupAbsRows))) + ...
                        strlength(string(editLogsOut.peakTime_after(groupAbsRows)));
                    maxScore = max(score);
                    bestRel = groupRelRows(score == maxScore);
                    keepAutoRelIdx(end+1,1) = bestRel(end); %#ok<AGROW>
                end
                keepMask = ~autoMask;
                keepMask(autoRows(keepAutoRelIdx)) = true;
                editLogsOut = editLogsOut(keepMask, :);
            end

            if ismember('timestamp', editLogsOut.Properties.VariableNames)
                editLogsOut = sortrows(editLogsOut, 'timestamp');
            end
        end

        function editLogs = normalizeEditLogTable(editLogs)
            editLogs = ECGManualInspector.normalizeEditLogTable(editLogs);
        end

        function peakTimes = buildSecondsPeakTimes(sampleIdx, fs)
            sampleIdx = double(sampleIdx(:));
            peakTimes = repmat("", numel(sampleIdx), 1);
            if isempty(sampleIdx)
                return
            end
            if nargin < 2
                fs = [];
            end
            if isempty(fs) || ~isfinite(fs) || fs <= 0
                return
            end
            validMask = isfinite(sampleIdx);
            if any(validMask)
                sampleRounded = round(sampleIdx(validMask));
                peakTimes(validMask) = string(seconds((sampleRounded - 1) ./ fs));
            end
        end

        function editOps = buildEditOpsTable(editLogs)
            editLogs = ECGArtifactLogManager.normalizeEditLogTable(editLogs);
            nRows = height(editLogs);
            opIndex = (1:nRows).';
            timestamp = editLogs.timestamp;
            action = editLogs.action;
            sample_before = editLogs.peak_before;
            sample_after = editLogs.peak_after;
            reason = editLogs.editTarget;
            note = editLogs.note;
            userId = editLogs.userId;
            sessionId = editLogs.sessionId;
            flagIndex = nan(nRows, 1);
            editOps = table(opIndex, timestamp, action, sample_before, sample_after, ...
                reason, note, userId, sessionId, flagIndex);
        end
    end
end
