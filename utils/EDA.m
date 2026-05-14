classdef EDA <handle
    properties(Constant)
        lowCutoffFrequency = 0.005 %Hz
        highCutoffFrequency = 5 %Hz
        % downsamplingFs = 16 % Hz (highest value)
        medianSmoothingWindow = 8;       % median window (s)
    end

    properties
        data
        fs
        downsamplingFs = 16 % Hz (highest value)
        eventArray = []
        ledaStruct
        timeArray
        phasicData
        edaArtifactIntervals = table()
        conductancePreprocessed = []
        conductanceCorrected = []
    end

    properties (Access=private)
        isPreprocessed = false
        tempFileName =''
        tempFilePath
        tempSaveDir
        downsamplingFactor
    end

    methods
        function obj = EDA(rawData, opts)
            if nargin < 2 || isempty(opts)
                opts = struct();
            end
            obj.validateRawData(rawData);
            obj.validateSamplingFrequencies(opts);
        end

        function preprocess(obj, varargin)
            if obj.isPreprocessed; return; end

            if ~isempty(varargin)
                parser = inputParser;
                parser.FunctionName = 'EDA.preprocess';
                addParameter(parser, 'artifactMode', "manual");
                parse(parser, varargin{:});
                artifactMode = parser.Results.artifactMode;
            end

            obj.runLedalabAnalysis("./PreprocessedEDA", artifactMode);
            obj.isPreprocessed = true;
        end

        function runLedalabAnalysis(obj,tempSaveDir,artifactMode)
            if nargin<2 || isempty(tempSaveDir); tempSaveDir = "./PreprocessedEDA"; end
            if nargin<3 || isempty(artifactMode); artifactMode = "none"; end
            obj.tempSaveDir = tempSaveDir;
            obj.prepareLedalabExecutionContext(tempSaveDir);
            obj.saveForLedalabAnalysis();
            obj.processWithLedalab(artifactMode);
            obj.deleteTemporalFile();
        end

        function processWithLedalab(obj, artifactMode)
            if nargin < 2 || isempty(artifactMode)
                artifactMode = "none";
            end
            if exist('Ledalab', 'file') ~= 2
                error('EDA:MissingLedalabDependency', ...
                    ['Ledalab was not found on the MATLAB path. ', ...
                     'Install/add Ledalab before running EDA preprocessing.']);
            end

            artifactMode = obj.resolveArtifactMode(artifactMode);
            if artifactMode == "manual"
                obj.runLedalabManualArtifactFlow();
            else
                obj.runLedalabFullPipelineNoArtifacts();
            end
        end

        function epochs = epochToId(obj,desiredEventId,window)
            if nargin<3; window = [-1,5];end

            filtered = obj.eventArray([obj.eventArray.nid]==desiredEventId);
            eventTimes = [filtered.time];
            eventName  = filtered(1).name;
            fprintf("Epoching to: %s \n",eventName);
            nbEvents = numel(eventTimes);

            epochs(nbEvents) = struct();

            for indEvent = 1:nbEvents
                t0 = eventTimes(indEvent);
                idx = find(obj.timeArray >= (t0 + window(1)) & obj.timeArray <= (t0 + window(2)));
                epochs(indEvent).time = obj.timeArray(idx)-t0;
                epochs(indEvent).phasic = obj.phasicData(idx);

            end

        end

         function [restoreCwd, cleanupTemp] = prepareLedalabExecutionContext(obj, tempSaveDir)
            projectRoot = EDA.getProjectRoot();
            tempSaveDir = string(tempSaveDir);
            if ~EDA.isAbsolutePath(tempSaveDir)
                tempSaveDir = fullfile(projectRoot, tempSaveDir);
            end
            obj.tempSaveDir = char(tempSaveDir);

            % protocolPath = fullfile(projectRoot, "batchmode_protocol.mat");
            % if exist(protocolPath, 'file') ~= 2
            %     error('EDA:MissingBatchmodeProtocol', ...
            %         'Missing batchmode_protocol.mat at %s', protocolPath);
            % end

            originalDir = pwd;
            restoreCwd = onCleanup(@() cd(originalDir));
            cd(projectRoot);

            obj.prepareTemporalSavingPath();
            cleanupTemp = onCleanup(@() obj.deleteTemporalFile());
        end
    end

    methods (Access=private)

        function validateRawData(obj,rawData)
            obj.data = rawData(~isnan(rawData));
        end

        function validateSamplingFrequencies(obj,opts)
            obj.fs = 2048; % Hz
            if isfield(opts, 'fs')
                samplingFrequency = double(opts.fs);
                if isfinite(samplingFrequency) && samplingFrequency > 0
                    obj.fs = samplingFrequency;
                end
            end
            obj.getDownsamplingFrequency();
        end

        function getDownsamplingFrequency(obj)
            divs = divisors(obj.fs);
            obj.downsamplingFs = max(divs(divs <= 16));       % largest divisor <= 16
            obj.downsamplingFactor = obj.fs / obj.downsamplingFs;

        end

        function prepareTemporalSavingPath(obj)
            if ~exist(obj.tempSaveDir, 'dir')
                mkdir(obj.tempSaveDir);
            end

            obj.getTempSaveName();
            obj.tempFilePath = fullfile(obj.tempSaveDir,obj.tempFileName);
        end

        function deleteTemporalFile(obj)
            if exist(obj.tempFilePath, 'file') == 2
                delete(obj.tempFilePath);
            end
        end

        function getTempSaveName(obj)
            if isempty(obj.tempFileName)
                [~,tempFileName,~] = fileparts(tempname);
                obj.tempFileName = [tempFileName,'.mat'];
            end
        end

        function saveForLedalabAnalysis(obj)
            data.conductance = obj.data;
            data.time        = (0:numel(data.conductance)-1)'/obj.fs;
            data.timeoff     = 0;
            data.event       = obj.eventArray;

            save(obj.tempFilePath,'data');
        end

        function artifactMode = resolveArtifactMode(obj, inputArtifactMode)
            artifactMode = inputArtifactMode;

            if isprop(obj, 'artifactMode')
                try
                    objectArtifactMode = obj.artifactMode;
                    if ~isempty(objectArtifactMode)
                        artifactMode = objectArtifactMode;
                    end
                catch
                    % Keep the input artifact mode if the object property access fails.
                end
            end

            artifactMode = EDA.normalizeArtifactMode(artifactMode);
        end

        function runLedalabFullPipelineNoArtifacts(obj)
            Ledalab( char(obj.tempFilePath), ...
                     'open',     'mat', ...    % load .mat
                     'filter',[1,EDA.highCutoffFrequency],...
                     'downsample',obj.downsamplingFactor,...
                     'smooth',     {'gauss', round(EDA.medianSmoothingWindow * obj.downsamplingFs)},      ...
                     'analyze',  'CDA', ...    % Continuous Decomposition
                     'optimize', 1 );          % fit model parameters

            global leda2
            obj.edaArtifactIntervals = obj.getEmptyArtifactIntervalTable();
            obj.conductancePreprocessed = [];
            obj.conductanceCorrected = [];
            obj.populateOutputsFromLedalab(leda2);
        end

        function runLedalabManualArtifactFlow(obj)
            % Manual mode intentionally runs preprocessing first, applies interval edits,
            % then runs CDA on the corrected preprocessed signal.
            obj.runLedalabPreprocessingOnly();

            global leda2
            [preprocessedConductance, preprocessedTime] = obj.extractPreprocessedConductanceAndTime(leda2);
            obj.conductancePreprocessed = preprocessedConductance;

            [correctedConductance, artifactIntervals, wasCancelled] = ...
                obj.manualRejectEdaArtifacts(preprocessedConductance, preprocessedTime, obj.downsamplingFs);
            if wasCancelled
                correctedConductance = preprocessedConductance;
                artifactIntervals = obj.getEmptyArtifactIntervalTable();
            end

            obj.conductanceCorrected = correctedConductance;
            obj.edaArtifactIntervals = artifactIntervals;

            obj.runLedalabCdaOnCorrectedSignal(correctedConductance, preprocessedTime, obj.eventArray);
            global leda2
            obj.populateOutputsFromLedalab(leda2);
        end

        function runLedalabPreprocessingOnly(obj)
            Ledalab( char(obj.tempFilePath), ...
                     'open',     'mat', ...    % load .mat
                     'filter',[1,EDA.highCutoffFrequency],...
                     'downsample',obj.downsamplingFactor,...
                     'smooth',     {'gauss', round(EDA.medianSmoothingWindow * obj.downsamplingFs)} );
        end

        function [conductance, timeVector] = extractPreprocessedConductanceAndTime(~, ledaStruct)
            conductance = EDA.extractLedalabVector(ledaStruct, ...
                {{'data','conductance','data'}, {'data','conductance'}});
            timeVector = EDA.extractLedalabVector(ledaStruct, ...
                {{'data','time','data'}, {'data','time'}});

            if isempty(conductance) || isempty(timeVector)
                error('EDA:LedalabPreprocessingExtractionFailed', ...
                    'Could not extract preprocessed conductance/time from Ledalab output.');
            end
            if numel(conductance) ~= numel(timeVector)
                error('EDA:LedalabPreprocessingLengthMismatch', ...
                    ['Preprocessed conductance and time vector length mismatch in Ledalab output ', ...
                     '(conductance=%d, time=%d).'], numel(conductance), numel(timeVector));
            end
        end

        function runLedalabCdaOnCorrectedSignal(obj, correctedConductance, timeVector, eventArray)
            correctedConductance = double(correctedConductance(:));
            if nargin < 4
                eventArray = obj.eventArray;
            end
            if nargin < 3 || isempty(timeVector)
                timeVector = (0:numel(correctedConductance)-1)'/obj.downsamplingFs;
            end
            timeVector = double(timeVector(:));

            if numel(correctedConductance) ~= numel(timeVector)
                error('EDA:CorrectedSignalLengthMismatch', ...
                    ['Corrected conductance and time vector must have equal lengths ', ...
                     '(conductance=%d, time=%d).'], numel(correctedConductance), numel(timeVector));
            end

            if ~exist(obj.tempSaveDir, 'dir')
                mkdir(obj.tempSaveDir);
            end

            [~, tempFileBaseName, ~] = fileparts(tempname);
            correctedTempPath = fullfile(obj.tempSaveDir, [tempFileBaseName, '_edaCorrected.mat']);

            data.conductance = correctedConductance;
            data.time = timeVector;
            data.timeoff = 0;
            data.event = eventArray;
            save(correctedTempPath, 'data');

            cleanupObj = onCleanup(@() EDA.safeDeleteIfExists(correctedTempPath)); %#ok<NASGU>

            Ledalab( char(correctedTempPath), ...
                     'open',    'mat', ...
                     'analyze', 'CDA', ...
                     'optimize', 1 );
        end

        function populateOutputsFromLedalab(obj, ledaStruct)
            obj.fs = obj.downsamplingFs;
            obj.ledaStruct = ledaStruct;
            obj.timeArray = obj.ledaStruct.data.time.data;
            obj.phasicData = obj.ledaStruct.analysis.phasicData;
            obj.data = table(obj.timeArray',obj.phasicData','VariableNames',{'Timestamp','Phasic'});
        end

        function [correctedConductance, artifactIntervals, wasCancelled] = ...
                manualRejectEdaArtifacts(obj, conductance, timeVector, fs)

            conductance = double(conductance(:));
            timeVector = double(timeVector(:));

            if nargin < 4 || isempty(fs) || ~isfinite(fs) || fs <= 0
                fs = obj.downsamplingFs;
            end
            if isempty(timeVector) || numel(timeVector) ~= numel(conductance)
                timeVector = (0:numel(conductance)-1)'/fs;
            end

            correctedConductance = conductance;
            artifactIntervals = obj.getEmptyArtifactIntervalTable();
            wasCancelled = false;

            if isempty(conductance)
                return
            end

            intervalBounds = zeros(0,2);
            previewConductance = conductance;
            previewApplied = false;
            wasCancelled = true;
            intervalPatchHandles = gobjects(0);

            hFig = figure( ...
                'Name', 'EDA Manual Artifact Rejection', ...
                'NumberTitle', 'off', ...
                'Color', 'w', ...
                'MenuBar', 'none', ...
                'ToolBar', 'figure', ...
                'WindowStyle', 'modal', ...
                'CloseRequestFcn', @onCancel);

            hAx = axes('Parent', hFig, 'Position', [0.07 0.16 0.62 0.78]); %#ok<LAXES>
            hold(hAx, 'on');
            plot(hAx, timeVector, conductance, 'Color', [0 0.35 0.74], ...
                'DisplayName', 'Preprocessed EDA');
            hPreview = plot(hAx, timeVector, conductance, '--', ...
                'Color', [0.85 0.1 0.1], ...
                'LineWidth', 1.2, ...
                'Visible', 'off', ...
                'DisplayName', 'Corrected Preview');
            xlabel(hAx, 'Time [s]');
            ylabel(hAx, 'Conductance');
            title(hAx, 'Manual EDA Artifact Rejection');
            grid(hAx, 'on');
            legend(hAx, 'Location', 'best');

            uicontrol('Parent', hFig, 'Style', 'text', ...
                'Position', [640 565 230 22], ...
                'String', 'Artifact Intervals', ...
                'HorizontalAlignment', 'left', ...
                'BackgroundColor', 'w', ...
                'FontWeight', 'bold');

            hList = uicontrol('Parent', hFig, 'Style', 'listbox', ...
                'Position', [640 360 230 210], ...
                'Max', 1, ...
                'Min', 0, ...
                'String', {'(No intervals)'});

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [640 325 110 28], ...
                'String', 'Add Interval', ...
                'Callback', @onAddInterval);

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [760 325 110 28], ...
                'String', 'Edit Selected', ...
                'Callback', @onEditInterval);

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [640 292 110 28], ...
                'String', 'Delete Selected', ...
                'Callback', @onDeleteInterval);

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [760 292 110 28], ...
                'String', 'Clear All', ...
                'Callback', @onClearIntervals);

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [640 250 110 30], ...
                'String', 'Preview Apply', ...
                'Callback', @onPreviewApply);

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [760 250 110 30], ...
                'String', 'Reset Preview', ...
                'Callback', @onResetPreview);

            uicontrol('Parent', hFig, 'Style', 'text', ...
                'Position', [640 205 230 35], ...
                'String', 'Add Interval: click start and end points on the trace.', ...
                'HorizontalAlignment', 'left', ...
                'BackgroundColor', 'w');

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [640 155 110 35], ...
                'String', 'Confirm', ...
                'FontWeight', 'bold', ...
                'Callback', @onConfirm);

            uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
                'Position', [760 155 110 35], ...
                'String', 'Cancel', ...
                'Callback', @onCancel);

            refreshEditorUi();
            uiwait(hFig);

            if isgraphics(hFig)
                delete(hFig);
            end

            function onAddInterval(~, ~)
                if ~isgraphics(hFig)
                    return
                end

                figure(hFig);
                axes(hAx);
                title(hAx, 'Click interval START and END');
                [xClicks, ~] = ginput(2);
                title(hAx, 'Manual EDA Artifact Rejection');
                if numel(xClicks) < 2
                    return
                end

                startTime = min(xClicks);
                endTime = max(xClicks);
                [startSample, endSample] = EDA.timeWindowToSampleBounds(timeVector, startTime, endTime);
                intervalBounds = [intervalBounds; [startSample, endSample]]; %#ok<AGROW>
                intervalBounds = EDA.mergeSampleBounds(intervalBounds, numel(conductance));
                previewApplied = false;
                previewConductance = conductance;
                refreshEditorUi();
            end

            function onEditInterval(~, ~)
                selectedIdx = getSelectedIntervalIndex();
                if isempty(selectedIdx)
                    return
                end

                startSample = intervalBounds(selectedIdx,1);
                endSample = intervalBounds(selectedIdx,2);
                prompt = {'Start time [s]:', 'End time [s]:'};
                defaults = {sprintf('%.6f', timeVector(startSample)), sprintf('%.6f', timeVector(endSample))};
                answer = inputdlg(prompt, 'Edit Artifact Interval', 1, defaults);
                if isempty(answer)
                    return
                end

                startTime = str2double(answer{1});
                endTime = str2double(answer{2});
                if ~(isfinite(startTime) && isfinite(endTime))
                    warndlg('Start/end time must be numeric.', 'Invalid Interval');
                    return
                end
                if startTime > endTime
                    tmp = startTime;
                    startTime = endTime;
                    endTime = tmp;
                end

                [newStartSample, newEndSample] = EDA.timeWindowToSampleBounds(timeVector, startTime, endTime);
                intervalBounds(selectedIdx,:) = [newStartSample, newEndSample];
                intervalBounds = EDA.mergeSampleBounds(intervalBounds, numel(conductance));
                previewApplied = false;
                previewConductance = conductance;
                refreshEditorUi();
            end

            function onDeleteInterval(~, ~)
                selectedIdx = getSelectedIntervalIndex();
                if isempty(selectedIdx)
                    return
                end

                intervalBounds(selectedIdx,:) = [];
                previewApplied = false;
                previewConductance = conductance;
                refreshEditorUi();
            end

            function onClearIntervals(~, ~)
                intervalBounds = zeros(0,2);
                previewApplied = false;
                previewConductance = conductance;
                refreshEditorUi();
            end

            function onPreviewApply(~, ~)
                artifactIntervalsPreview = obj.buildArtifactIntervalTableFromBounds(intervalBounds, timeVector);
                previewConductance = obj.applyEdaArtifactIntervals(conductance, artifactIntervalsPreview);
                previewApplied = true;
                refreshEditorUi();
            end

            function onResetPreview(~, ~)
                previewConductance = conductance;
                previewApplied = false;
                refreshEditorUi();
            end

            function onConfirm(~, ~)
                artifactIntervals = obj.buildArtifactIntervalTableFromBounds(intervalBounds, timeVector);
                if previewApplied
                    correctedConductance = previewConductance;
                else
                    correctedConductance = obj.applyEdaArtifactIntervals(conductance, artifactIntervals);
                end
                wasCancelled = false;
                closeEditor();
            end

            function onCancel(~, ~)
                artifactIntervals = obj.getEmptyArtifactIntervalTable();
                correctedConductance = conductance;
                wasCancelled = true;
                closeEditor();
            end

            function closeEditor()
                if isgraphics(hFig)
                    uiresume(hFig);
                    delete(hFig);
                end
            end

            function selectedIdx = getSelectedIntervalIndex()
                if isempty(intervalBounds)
                    selectedIdx = [];
                    return
                end

                selectedIdx = get(hList, 'Value');
                if isempty(selectedIdx) || selectedIdx < 1 || selectedIdx > size(intervalBounds,1)
                    selectedIdx = [];
                end
            end

            function refreshEditorUi()
                if ~isempty(intervalPatchHandles)
                    validPatchMask = isgraphics(intervalPatchHandles);
                    delete(intervalPatchHandles(validPatchMask));
                end
                intervalPatchHandles = gobjects(0);

                yLimits = get(hAx, 'YLim');
                for intervalIndex = 1:size(intervalBounds,1)
                    startTime = timeVector(intervalBounds(intervalIndex,1));
                    endTime = timeVector(intervalBounds(intervalIndex,2));
                    intervalPatchHandles(intervalIndex,1) = patch(hAx, ...
                        [startTime endTime endTime startTime], ...
                        [yLimits(1) yLimits(1) yLimits(2) yLimits(2)], ...
                        [1 0.6 0.1], ...
                        'FaceAlpha', 0.15, ...
                        'EdgeColor', 'none', ...
                        'HandleVisibility', 'off');
                end

                if isempty(intervalBounds)
                    set(hList, 'String', {'(No intervals)'}, 'Value', 1);
                else
                    intervalRows = cell(size(intervalBounds,1),1);
                    for intervalIndex = 1:size(intervalBounds,1)
                        startSample = intervalBounds(intervalIndex,1);
                        endSample = intervalBounds(intervalIndex,2);
                        intervalRows{intervalIndex} = sprintf( ...
                            '%d) %.3fs - %.3fs  [%d:%d]', ...
                            intervalIndex, ...
                            timeVector(startSample), ...
                            timeVector(endSample), ...
                            startSample, ...
                            endSample);
                    end
                    currentValue = get(hList, 'Value');
                    currentValue = min(max(currentValue, 1), size(intervalBounds,1));
                    set(hList, 'String', intervalRows, 'Value', currentValue);
                end

                if previewApplied
                    set(hPreview, 'YData', previewConductance, 'Visible', 'on');
                else
                    set(hPreview, 'Visible', 'off');
                end

                drawnow;
            end
        end

        function correctedConductance = applyEdaArtifactIntervals(obj, conductance, artifactIntervals)
            %#ok<INUSD>
            conductance = double(conductance(:));
            correctedConductance = conductance;

            if isempty(artifactIntervals) || ~istable(artifactIntervals) || height(artifactIntervals) == 0
                return
            end
            requiredVariables = {'startSample','endSample'};
            if ~all(ismember(requiredVariables, artifactIntervals.Properties.VariableNames))
                error('EDA:InvalidArtifactIntervalTable', ...
                    'Artifact interval table must contain startSample and endSample.');
            end

            intervalBounds = [artifactIntervals.startSample, artifactIntervals.endSample];
            intervalBounds = EDA.mergeSampleBounds(intervalBounds, numel(correctedConductance));
            if isempty(intervalBounds)
                return
            end

            for intervalIndex = 1:size(intervalBounds,1)
                startSample = intervalBounds(intervalIndex,1);
                endSample = intervalBounds(intervalIndex,2);

                if startSample == 1 && endSample == numel(correctedConductance)
                    warning('EDA:ArtifactIntervalCoversFullSignal', ...
                        'An artifact interval covers the entire signal. Interval was left unchanged.');
                    continue
                end

                if startSample == 1
                    rightReference = min(numel(correctedConductance), endSample + 1);
                    correctedConductance(startSample:endSample) = correctedConductance(rightReference);
                    continue
                end

                if endSample == numel(correctedConductance)
                    leftReference = max(1, startSample - 1);
                    correctedConductance(startSample:endSample) = correctedConductance(leftReference);
                    continue
                end

                leftReference = startSample - 1;
                rightReference = endSample + 1;
                targetSamples = startSample:endSample;
                correctedConductance(targetSamples) = interp1( ...
                    [leftReference; rightReference], ...
                    [correctedConductance(leftReference); correctedConductance(rightReference)], ...
                    targetSamples, 'linear');
            end
        end

        function artifactIntervals = buildArtifactIntervalTableFromBounds(obj, intervalBounds, timeVector)
            %#ok<INUSD>
            if isempty(intervalBounds)
                artifactIntervals = obj.getEmptyArtifactIntervalTable();
                return
            end

            intervalBounds = EDA.mergeSampleBounds(intervalBounds, numel(timeVector));
            if isempty(intervalBounds)
                artifactIntervals = obj.getEmptyArtifactIntervalTable();
                return
            end

            startSample = double(intervalBounds(:,1));
            endSample = double(intervalBounds(:,2));
            startTime = double(timeVector(startSample));
            endTime = double(timeVector(endSample));
            action = repmat("linear_interpolate", size(intervalBounds,1), 1);
            artifactIntervals = table(startSample, endSample, startTime, endTime, action, ...
                'VariableNames', {'startSample','endSample','startTime','endTime','action'});
        end

        function artifactIntervals = getEmptyArtifactIntervalTable(~)
            artifactIntervals = table('Size', [0 5], ...
                'VariableTypes', {'double','double','double','double','string'}, ...
                'VariableNames', {'startSample','endSample','startTime','endTime','action'});
        end

    end

    methods(Static)
        function p = getDefaultPreprocessParams()
            p = struct('artifactMode', "none");
        end
    end

    methods (Static, Access=private)
        function normalizedMode = normalizeArtifactMode(modeIn)
            mode = string(modeIn);
            mode = mode(:);
            if isempty(mode)
                mode = "none";
            else
                mode = mode(1);
            end
            mode = lower(strtrim(mode));
            if strlength(mode) == 0
                normalizedMode = "none";
                return
            end

            if any(mode == ["manual","semiauto","semiautomatic"])
                normalizedMode = "manual";
                return
            end

            if any(mode == ["none","skip","ignore","off","false","no"])
                normalizedMode = "none";
                return
            end

            warning('EDA:UnknownArtifactMode', ...
                'Unknown artifact mode "%s". Falling back to "none".', mode);
            normalizedMode = "none";
        end

        function vector = extractLedalabVector(ledaStruct, candidatePaths)
            vector = [];
            for pathIndex = 1:numel(candidatePaths)
                candidateValue = EDA.getNestedStructField(ledaStruct, candidatePaths{pathIndex});
                if isnumeric(candidateValue) && isvector(candidateValue) && ~isempty(candidateValue)
                    vector = double(candidateValue(:));
                    return
                end
            end
        end

        function nestedValue = getNestedStructField(rootStruct, fieldPath)
            nestedValue = rootStruct;
            for fieldIndex = 1:numel(fieldPath)
                fieldName = fieldPath{fieldIndex};
                if ~isstruct(nestedValue) || ~isfield(nestedValue, fieldName)
                    nestedValue = [];
                    return
                end
                nestedValue = nestedValue.(fieldName);
            end
        end

        function [startSample, endSample] = timeWindowToSampleBounds(timeVector, startTime, endTime)
            [~, startSample] = min(abs(timeVector - startTime));
            [~, endSample] = min(abs(timeVector - endTime));
            if startSample > endSample
                tmp = startSample;
                startSample = endSample;
                endSample = tmp;
            end
        end

        function mergedBounds = mergeSampleBounds(intervalBounds, nSamples)
            if isempty(intervalBounds)
                mergedBounds = zeros(0,2);
                return
            end

            if size(intervalBounds,2) ~= 2
                error('EDA:InvalidIntervalBounds', 'Interval bounds must be an Nx2 matrix.');
            end

            bounds = double(intervalBounds);
            validRows = all(isfinite(bounds),2);
            bounds = bounds(validRows,:);
            if isempty(bounds)
                mergedBounds = zeros(0,2);
                return
            end

            bounds = round(bounds);
            bounds(:,1) = max(1, bounds(:,1));
            bounds(:,2) = min(nSamples, bounds(:,2));

            swapMask = bounds(:,1) > bounds(:,2);
            bounds(swapMask,:) = bounds(swapMask,[2,1]);
            bounds = bounds(bounds(:,1) <= bounds(:,2), :);
            if isempty(bounds)
                mergedBounds = zeros(0,2);
                return
            end

            bounds = sortrows(bounds, 1);
            mergedBounds = bounds(1,:);
            for idx = 2:size(bounds,1)
                currentBounds = bounds(idx,:);
                if currentBounds(1) <= mergedBounds(end,2) + 1
                    mergedBounds(end,2) = max(mergedBounds(end,2), currentBounds(2));
                else
                    mergedBounds(end+1,:) = currentBounds; %#ok<AGROW>
                end
            end
        end

        function projectRoot = getProjectRoot()
            thisFileDir = fileparts(mfilename('fullpath'));
            projectRoot = fileparts(thisFileDir);
        end

        function tf = isAbsolutePath(pathValue)
            pathValue = char(string(pathValue));
            if isempty(pathValue)
                tf = false;
                return
            end

            tf = ~isempty(regexp(pathValue, '^[A-Za-z]:[\\/]', 'once')) || ...
                startsWith(pathValue, '\\') || ...
                startsWith(pathValue, '/');
        end
        function safeDeleteIfExists(filePath)
            if exist(filePath, 'file') == 2
                delete(filePath);
            end
        end
    end
end
