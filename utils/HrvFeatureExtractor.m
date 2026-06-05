classdef HrvFeatureExtractor < handle
    properties (Constant)
        vlfBand = [0.0033 0.04]
        lfBand = [0.04 0.15]
        hfBand = [0.15 0.40]
    end

    properties
        sources = struct()
        epochedData = struct()
        eventArray = []
        participantId = ""
        hrv = struct()
    end

    methods
        function obj = HrvFeatureExtractor(opts)
            arguments
                opts.sources = struct()
                opts.epochedData = struct()
                opts.eventArray = []
                opts.participantId = ""
            end

            obj.sources = opts.sources;
            obj.epochedData = opts.epochedData;
            obj.eventArray = opts.eventArray;
            obj.participantId = string(opts.participantId);
        end

        function hrv = extract(obj, opts)
            arguments
                obj
                opts.baselineDurationSec (1,1) double = 300
                opts.baselineMethod (1,1) string = "preFirstEvent"
                opts.baselineFallbackMethod (1,1) string = "firstAvailable"
                opts.minDurationForSpectrumSec (1,1) double = 1
                opts.interpHz (1,1) double = 4
                opts.baselineWindowSec = []
            end

            tonicFeatures = obj.getTonicFeatures(opts);
            epochFeatures = obj.getEpochFeatures(opts);

            obj.hrv = struct();
            obj.hrv.tonicFeatures = tonicFeatures;
            obj.hrv.epochFeatures = epochFeatures;
            hrv = obj.hrv;
        end

        function save(obj, opts)
            arguments
                obj
                opts.saveDir = ""
                opts.saveMode (1,1) string = "asParquet"
            end

            if strlength(opts.saveDir) == 0
                return
            end

            if isempty(obj.hrv) || ~isstruct(obj.hrv)
                return
            end

            if ~exist(opts.saveDir, 'dir')
                mkdir(opts.saveDir);
            end

            saveMode = string(NameSchema.validateSavingMode(opts.saveMode));
            extension = HrvFeatureExtractor.getSaveExtension(saveMode);

            if isfield(obj.hrv, 'tonicFeatures')
                obj.writeFeatureTable(obj.hrv.tonicFeatures, opts.saveDir, extension, saveMode, "baseline");
            end

            if isfield(obj.hrv, 'epochFeatures')
                obj.writeFeatureTable(obj.hrv.epochFeatures, opts.saveDir, extension, saveMode, "epoch");
            end
        end

        function tonicFeatures = getTonicFeatures(obj, opts)

            hasCleanedRri = isfield(obj.sources, 'ECG') && ...
                            isprop(obj.sources.ECG, 'rri') && ...
                            istable(obj.sources.ECG.rri) && ...
                            ~isempty(obj.sources.ECG.rri) && ...
                            all(ismember(["Timestamp","RRI"], ...
                                string(obj.sources.ECG.rri.Properties.VariableNames)));

            if ~hasCleanedRri
                warning('Could not find cleaned RRI table, skipping Tonic feature extraction.');
                tonicFeatures = table();
                return
            end

            baselineTable = obj.sources.ECG.rri;

            tonicFeatures = table();
            [baselineSelection, hasBaseline] = obj.selectBaselineWindow(baselineTable, opts);
            if hasBaseline
                tonicFeatures = HrvFeatureExtractor.computeBaselineFeatures(baselineSelection, opts);
                if ~isempty(tonicFeatures)
                    tonicFeatures.segmentType = "baseline";
                    tonicFeatures.task = "baseline";
                    tonicFeatures.trial = NaN;
                    tonicFeatures.eventID = NaN;
                    tonicFeatures = obj.orderHrvColumns(tonicFeatures);
                end
            end
        end

        function epochFeatures = getEpochFeatures(obj, opts)

            hasEpochedRri = isfield(obj.epochedData, 'RRI') && isstruct(obj.epochedData.RRI) && ...
                any(structfun(@(value) istable(value) && ~isempty(value) && ...
                    all(ismember(["Timestamp","RRI","trial","eventID"], string(value.Properties.VariableNames))), ...
                    obj.epochedData.RRI));

            if ~hasEpochedRri
                warning('Could not find data in the epoched RRI table, skipping Epoched feature extraction.');
                epochFeatures = table();
                return
            end

            epochFeatures = table();
            taskNames = fieldnames(obj.epochedData.RRI);
            for taskIndex = 1:numel(taskNames)
                taskName = taskNames{taskIndex};
                epochTable = obj.epochedData.RRI.(taskName);
                if isempty(epochTable) || ~istable(epochTable)
                    continue
                end
                taskFeatures = HrvFeatureExtractor.computeEpochFeatures(epochTable, string(taskName), opts);
                if isempty(taskFeatures)
                    continue
                end
                taskFeatures.segmentType = repmat("epoch", height(taskFeatures), 1);
                taskFeatures.task = repmat(string(taskName), height(taskFeatures), 1);
                taskFeatures = obj.orderHrvColumns(taskFeatures);
                epochFeatures = [epochFeatures; taskFeatures];
            end
        end
    end

    methods (Static)
        function timeDomainRow = computeTimeDomainFeatures(rriMs)
            meanRriMs = NaN;
            meanHrBpm = NaN;
            rmssdMs = NaN;

            if ~isempty(rriMs)
                meanRriMs = mean(rriMs, 'omitnan');
                if isfinite(meanRriMs) && meanRriMs > 0
                    meanHrBpm = 60000 / meanRriMs;
                end
                if numel(rriMs) >= 3
                    diffs = diff(rriMs);
                    rmssdMs = sqrt(mean(diffs .^ 2, 'omitnan'));
                end
            end

            timeDomainRow = struct( ...
                'meanRriMs', meanRriMs, ...
                'meanHrBpm', meanHrBpm, ...
                'rmssdMs', rmssdMs);
        end

        function freqDomainRow = computeFrequencyDomainFeatures(timestampSec, rriMs, opts)
            hasReliableSpectrum = false;
            vlfPower = NaN;
            lfPower = NaN;
            hfPower = NaN;
            lfHfRatio = NaN;

            if isempty(timestampSec) || isempty(rriMs)
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end

            timestampSec = double(timestampSec(:));
            rriMs = double(rriMs(:));
            validMask = isfinite(timestampSec) & isfinite(rriMs);
            timestampSec = timestampSec(validMask);
            rriMs = rriMs(validMask);

            if isempty(timestampSec)
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end

            durationSec = max(timestampSec) - min(timestampSec);
            if durationSec < opts.minDurationForSpectrumSec
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end

            [timestampSec, sortIdx] = sort(timestampSec);
            rriMs = rriMs(sortIdx);
            [timestampSec, uniqueIdx] = unique(timestampSec, 'stable');
            rriMs = rriMs(uniqueIdx);

            if numel(timestampSec) < 3
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end

            rriSec = rriMs / 1000;
            gridStep = 1 / opts.interpHz;
            uniformTime = (timestampSec(1):gridStep:timestampSec(end)).';
            rriInterp = interp1(timestampSec, rriSec, uniformTime, 'pchip');
            finiteMask = isfinite(rriInterp);
            if ~any(finiteMask)
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end
            firstIdx = find(finiteMask, 1, 'first');
            lastIdx = find(finiteMask, 1, 'last');
            rriInterp = rriInterp(firstIdx:lastIdx);

            if numel(rriInterp) < 4
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end

            detrended = detrend(rriInterp);
            windowLength = min(256, numel(detrended));
            overlap = floor(windowLength / 2);
            [psd, freq] = pwelch(detrended, windowLength, overlap, [], opts.interpHz);

            if numel(freq) < 2
                freqDomainRow = struct( ...
                    'hasReliableSpectrum', hasReliableSpectrum, ...
                    'vlfPower', vlfPower, ...
                    'lfPower', lfPower, ...
                    'hfPower', hfPower, ...
                    'lfHfRatio', lfHfRatio);
                return
            end

            freqResolution = mean(diff(freq));
            vlfPower = HrvFeatureExtractor.integrateBand(freq, psd, HrvFeatureExtractor.vlfBand, freqResolution);
            lfPower = HrvFeatureExtractor.integrateBand(freq, psd, HrvFeatureExtractor.lfBand, freqResolution);
            hfPower = HrvFeatureExtractor.integrateBand(freq, psd, HrvFeatureExtractor.hfBand, freqResolution);
            if isfinite(hfPower) && hfPower > 0
                lfHfRatio = lfPower / hfPower;
            end
            hasReliableSpectrum = true;

            freqDomainRow = struct( ...
                'hasReliableSpectrum', hasReliableSpectrum, ...
                'vlfPower', vlfPower, ...
                'lfPower', lfPower, ...
                'hfPower', hfPower, ...
                'lfHfRatio', lfHfRatio);
        end

        function featureTable = computeBaselineFeatures(baselineTable, opts)
            if isempty(baselineTable) || ~istable(baselineTable)
                featureTable = table();
                return
            end

            if ~all(ismember({'Timestamp','RRI'}, baselineTable.Properties.VariableNames))
                featureTable = table();
                return
            end

            timestampSec = baselineTable.Timestamp;
            if isduration(timestampSec)
                timestampSec = seconds(timestampSec);
            end
            timestampSec = double(timestampSec(:));
            rriMs = double(baselineTable.RRI(:));

            if isempty(timestampSec)
                featureTable = table();
                return
            end

            startTime = min(timestampSec);
            endTime = max(timestampSec);
            durationSec = endTime - startTime;
            nIntervals = double(numel(rriMs));

            timeDomainRow = HrvFeatureExtractor.computeTimeDomainFeatures(rriMs);
            freqDomainRow = HrvFeatureExtractor.computeFrequencyDomainFeatures(timestampSec, rriMs, opts);

            featureTable = table( ...
                startTime, endTime, durationSec, nIntervals, ...
                freqDomainRow.hasReliableSpectrum, ...
                timeDomainRow.meanRriMs, timeDomainRow.meanHrBpm, timeDomainRow.rmssdMs, ...
                freqDomainRow.vlfPower, freqDomainRow.lfPower, freqDomainRow.hfPower, freqDomainRow.lfHfRatio, ...
                'VariableNames', {'startTime','endTime','durationSec','nIntervals', ...
                'hasReliableSpectrum','meanRriMs','meanHrBpm','rmssdMs', ...
                'vlfPower','lfPower','hfPower','lfHfRatio'});
        end

        function featureTable = computeEpochFeatures(epochTable, taskName, opts)
            if isempty(epochTable) || ~istable(epochTable)
                featureTable = table();
                return
            end

            requiredVars = {'Timestamp','RRI','trial','eventID'};
            if ~all(ismember(requiredVars, epochTable.Properties.VariableNames))
                featureTable = table();
                return
            end

            groupKeys = findgroups(epochTable.trial, epochTable.eventID);
            nGroups = max(groupKeys);
            if nGroups == 0
                featureTable = table();
                return
            end

            trialValues = NaN(nGroups, 1);
            eventValues = NaN(nGroups, 1);
            startTimes = NaN(nGroups, 1);
            endTimes = NaN(nGroups, 1);
            durationSecs = NaN(nGroups, 1);
            nIntervals = NaN(nGroups, 1);
            hasReliableSpectrum = false(nGroups, 1);
            meanRriMs = NaN(nGroups, 1);
            meanHrBpm = NaN(nGroups, 1);
            rmssdMs = NaN(nGroups, 1);
            vlfPower = NaN(nGroups, 1);
            lfPower = NaN(nGroups, 1);
            hfPower = NaN(nGroups, 1);
            lfHfRatio = NaN(nGroups, 1);

            for groupIndex = 1:nGroups
                groupMask = groupKeys == groupIndex;
                groupTable = epochTable(groupMask, :);
                if isempty(groupTable)
                    continue
                end

                groupTrial = groupTable.trial(1);
                groupEvent = groupTable.eventID(1);

                timestampSec = groupTable.Timestamp;
                if isduration(timestampSec)
                    timestampSec = seconds(timestampSec);
                end
                timestampSec = double(timestampSec(:));
                rriMs = double(groupTable.RRI(:));

                if isempty(timestampSec)
                    continue
                end

                timeDomainRow = HrvFeatureExtractor.computeTimeDomainFeatures(rriMs);
                freqDomainRow = HrvFeatureExtractor.computeFrequencyDomainFeatures(timestampSec, rriMs, opts);

                trialValues(groupIndex) = double(groupTrial);
                eventValues(groupIndex) = double(groupEvent);
                startTimes(groupIndex) = min(timestampSec);
                endTimes(groupIndex) = max(timestampSec);
                durationSecs(groupIndex) = endTimes(groupIndex) - startTimes(groupIndex);
                nIntervals(groupIndex) = double(numel(rriMs));
                hasReliableSpectrum(groupIndex) = freqDomainRow.hasReliableSpectrum;
                meanRriMs(groupIndex) = timeDomainRow.meanRriMs;
                meanHrBpm(groupIndex) = timeDomainRow.meanHrBpm;
                rmssdMs(groupIndex) = timeDomainRow.rmssdMs;
                vlfPower(groupIndex) = freqDomainRow.vlfPower;
                lfPower(groupIndex) = freqDomainRow.lfPower;
                hfPower(groupIndex) = freqDomainRow.hfPower;
                lfHfRatio(groupIndex) = freqDomainRow.lfHfRatio;
            end

            featureTable = table( ...
                trialValues, eventValues, startTimes, endTimes, durationSecs, nIntervals, ...
                hasReliableSpectrum, meanRriMs, meanHrBpm, rmssdMs, ...
                vlfPower, lfPower, hfPower, lfHfRatio, ...
                'VariableNames', {'trial','eventID','startTime','endTime','durationSec','nIntervals', ...
                'hasReliableSpectrum','meanRriMs','meanHrBpm','rmssdMs', ...
                'vlfPower','lfPower','hfPower','lfHfRatio'});
        end
    end

    methods (Access=private)
        function [baselineSelection, hasBaseline] = selectBaselineWindow(obj, baselineTable, opts)
            baselineSelection = table();
            hasBaseline = false;

            if isempty(baselineTable) || ~istable(baselineTable)
                return
            end

            fixedBaselineWindowSec = [];
            if isfield(opts, 'baselineWindowSec')
                fixedBaselineWindowSec = HrvFeatureExtractor.normalizeBaselineWindowSec(opts.baselineWindowSec);
            end
            if ~isempty(fixedBaselineWindowSec)
                [baselineSelection, hasBaseline] = obj.selectWindowFromFixedBounds( ...
                    baselineTable, fixedBaselineWindowSec);
                return
            end

            baselineDuration = opts.baselineDurationSec;
            baselineMethod = lower(strtrim(string(opts.baselineMethod)));
            fallbackMethod = lower(strtrim(string(opts.baselineFallbackMethod)));

            switch baselineMethod
                case {"prefirstevent","pre_first_event"}
                    [baselineSelection, hasBaseline] = obj.selectWindowPreFirstEvent(baselineTable, baselineDuration);
                case {"firstavailable","fromstart","start"}
                    [baselineSelection, hasBaseline] = obj.selectWindowFromStart(baselineTable, baselineDuration);
                case {"lastavailable","fromend","end"}
                    [baselineSelection, hasBaseline] = obj.selectWindowFromEnd(baselineTable, baselineDuration);
                otherwise
                    warning('HrvFeatureExtractor:UnknownBaselineMethod', ...
                        'Unknown baselineMethod "%s"; using preFirstEvent.', opts.baselineMethod);
                    [baselineSelection, hasBaseline] = obj.selectWindowPreFirstEvent(baselineTable, baselineDuration);
            end

            if ~hasBaseline
                [baselineSelection, hasBaseline] = obj.applyBaselineFallback( ...
                    baselineTable, baselineDuration, fallbackMethod);
            end
        end

        function [selection, hasSelection] = selectWindowFromStart(obj, baselineTable, durationSec)
            timestampSec = baselineTable.Timestamp;
            if isduration(timestampSec)
                timestampSec = seconds(timestampSec);
            end
            timestampSec = double(timestampSec(:));
            hasSelection = false;
            selection = table();
            if isempty(timestampSec)
                return
            end
            startTime = min(timestampSec);
            endTime = startTime + durationSec;
            if max(timestampSec) - startTime >= durationSec
                mask = timestampSec >= startTime & timestampSec < endTime;
                selection = baselineTable(mask, :);
            else
                selection = baselineTable;
            end
            hasSelection = ~isempty(selection);
        end

        function [selection, hasSelection] = selectWindowFromEnd(obj, baselineTable, durationSec)
            timestampSec = baselineTable.Timestamp;
            if isduration(timestampSec)
                timestampSec = seconds(timestampSec);
            end
            timestampSec = double(timestampSec(:));

            hasSelection = false;
            selection = table();
            if isempty(timestampSec)
                return
            end

            endTime = max(timestampSec);
            startTime = endTime - durationSec;
            if endTime - min(timestampSec) >= durationSec
                mask = timestampSec >= startTime & timestampSec < endTime;
                selection = baselineTable(mask, :);
            else
                selection = baselineTable;
            end
            hasSelection = ~isempty(selection);
        end

        function [selection, hasSelection] = selectWindowPreFirstEvent(obj, baselineTable, durationSec)
            if isempty(obj.eventArray) || ~isstruct(obj.eventArray) || ~isfield(obj.eventArray, 'time')
                [selection, hasSelection] = obj.selectWindowFromStart(baselineTable, durationSec);
                return
            end

            eventTimes = double([obj.eventArray.time]);
            eventTimes = eventTimes(isfinite(eventTimes));
            if isempty(eventTimes)
                [selection, hasSelection] = obj.selectWindowFromStart(baselineTable, durationSec);
                return
            end
            earliestEventTime = min(eventTimes);
            if earliestEventTime < durationSec
                [selection, hasSelection] = obj.selectWindowFromStart(baselineTable, durationSec);
                return
            end

            timestampSec = baselineTable.Timestamp;
            if isduration(timestampSec)
                timestampSec = seconds(timestampSec);
            end
            timestampSec = double(timestampSec(:));

            endTimestamp = earliestEventTime;
            startTimestamp = endTimestamp - durationSec;
            mask = timestampSec >= startTimestamp & timestampSec <= endTimestamp;
            selection = baselineTable(mask, :);
            hasSelection = ~isempty(selection);
        end

        function [selection, hasSelection] = selectWindowFromFixedBounds(~, baselineTable, baselineWindowSec)
            timestampSec = baselineTable.Timestamp;
            if isduration(timestampSec)
                timestampSec = seconds(timestampSec);
            end

            timestampSec = double(timestampSec(:));
            selection = table();
            hasSelection = false;
            if isempty(timestampSec)
                return
            end

            mask = isfinite(timestampSec) & ...
                timestampSec >= baselineWindowSec(1) & ...
                timestampSec <= baselineWindowSec(2);
            selection = baselineTable(mask, :);
            hasSelection = ~isempty(selection);
        end

        function [selection, hasSelection] = applyBaselineFallback(obj, baselineTable, durationSec, fallbackMethod)
            switch fallbackMethod
                case {"firstavailable","fromstart","start"}
                    [selection, hasSelection] = obj.selectWindowFromStart(baselineTable, durationSec);
                case {"lastavailable","fromend","end"}
                    [selection, hasSelection] = obj.selectWindowFromEnd(baselineTable, durationSec);
                case {"fullrecording","all","entire"}
                    selection = baselineTable;
                    hasSelection = ~isempty(selection);
                case {"none","off",""}
                    selection = table();
                    hasSelection = false;
                otherwise
                    warning('HrvFeatureExtractor:UnknownBaselineFallbackMethod', ...
                        'Unknown baselineFallbackMethod "%s"; using firstAvailable.', fallbackMethod);
                    [selection, hasSelection] = obj.selectWindowFromStart(baselineTable, durationSec);
            end
        end

        function durationSec = computeDurationSec(obj, tableSegment)
            durationSec = 0;
            if isempty(tableSegment) || ~istable(tableSegment)
                return
            end
            if ~ismember('Timestamp', tableSegment.Properties.VariableNames)
                return
            end
            ts = tableSegment.Timestamp;
            if isduration(ts)
                ts = seconds(ts);
            end
            ts = double(ts(:));
            if isempty(ts)
                return
            end
            durationSec = max(ts) - min(ts);
        end

        function ordered = orderHrvColumns(obj, inputTable)
            if isempty(inputTable)
                ordered = inputTable;
                return
            end
            orderedNames = ["segmentType","task","trial","eventID","startTime","endTime", ...
                "durationSec","nIntervals","hasReliableSpectrum","meanRriMs","meanHrBpm", ...
                "rmssdMs","vlfPower","lfPower","hfPower","lfHfRatio"];
            rowCount = height(inputTable);
            for name = orderedNames
                if ismember(name, inputTable.Properties.VariableNames)
                    continue
                end
                switch name
                    case {"segmentType","task"}
                        inputTable.(name) = repmat("", rowCount, 1);
                    case "hasReliableSpectrum"
                        inputTable.(name) = false(rowCount, 1);
                    otherwise
                        inputTable.(name) = NaN(rowCount, 1);
                end
            end
            ordered = inputTable(:, orderedNames);
        end

        function writeFeatureTable(obj, featureTable, saveDir, extension, saveMode, taskName)
            if isempty(featureTable) || ~istable(featureTable)
                return
            end

            filePath = obj.buildSavePath(saveDir, taskName, extension);
            switch saveMode
                case "asParquet"
                    parquetwrite(filePath, featureTable);
                case "asCSV"
                    writetable(featureTable, filePath);
                case "asMat"
                    hrvFeatures = featureTable;
                    save(filePath, "hrvFeatures", "-v7.3");
                otherwise
                    error("Unrecognized save mode %s", saveMode);
            end
        end

        function filePath = buildSavePath(obj, saveDir, taskName, extension)
            fileName = NameSchema.format( ...
                participantId = obj.participantId, ...
                dataType = "HRV", ...
                taskName = taskName, ...
                binningMode = "byTimepoints", ...
                timeBinIdx = 0, ...
                extension = extension);
            filePath = fullfile(saveDir, fileName);
        end
    end

    methods (Static, Access=private)
        function baselineWindowSec = normalizeBaselineWindowSec(rawWindow)
            baselineWindowSec = [];
            if isempty(rawWindow)
                return
            end

            if isduration(rawWindow)
                rawWindow = seconds(rawWindow);
            end

            rawWindow = double(rawWindow(:).');
            if numel(rawWindow) ~= 2 || any(~isfinite(rawWindow))
                warning('HrvFeatureExtractor:InvalidBaselineWindowSec', ...
                    'baselineWindowSec must be a finite two-element numeric vector.');
                return
            end

            if rawWindow(2) <= rawWindow(1)
                warning('HrvFeatureExtractor:InvalidBaselineWindowSec', ...
                    'baselineWindowSec end time must be greater than start time.');
                return
            end

            baselineWindowSec = rawWindow;
        end

        function extension = getSaveExtension(saveMode)
            switch saveMode
                case "asCSV"
                    extension = ".csv";
                case "asParquet"
                    extension = ".parquet";
                case "asMat"
                    extension = ".mat";
                otherwise
                    error("Unrecognized save mode %s", saveMode);
            end
        end

        function power = integrateBand(freq, psd, band, freqResolution)
            mask = freq >= band(1) & freq < band(2);
            if any(mask)
                power = sum(psd(mask)) * freqResolution;
            else
                power = NaN;
            end
        end
    end
end
