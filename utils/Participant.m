classdef Participant < handle
    properties (Constant)
        defaultSourcesToExtract = {'ECG','EDA'};
        saveDirectoryName = fullfile("DataProcessed","ByParticipant")
    end

    properties 
        sources = struct()
        participantDataPath
        acqParser = []
        participantId
        invalidParticipant = false
        epochedData = struct()
        hrv
        hrvExtractor
        saveDir
        experimentName %{'ROSES','PANDA'}
        taskSegmentation
        sourcesToExtract = Participant.defaultSourcesToExtract
        segmentationProvided 
    end
    
    properties (Access=private)
        isPreProcessed = false
        saveResults = struct( ...
            'epochedData', true, ...
            'nonSegmentedData', true, ...
            'features', true)
    end
    
    methods 
        function obj = Participant(participantDataPath)
            obj.participantDataPath = participantDataPath;
            obj.inferExperiment();
            obj.getParticipantId();
            obj.prepareSaveDirectory();
        end
        
        function runPreprocessing(obj,opts)
            arguments 
                obj
                opts.save = true
                opts.ecgArtifactRejectionMethod = "trim"
                opts.ecgQCSaveDir = ""
                opts.taskSegmentation = struct('name', {}, 'events', {});
                opts.sourcesToExtract = Participant.defaultSourcesToExtract
            end

            obj.saveResults = Participant.parseSaveSelection(opts.save);
            % shouldSaveAnyOutputs = Participant.hasAnySaveEnabled(obj.saveResults);
            if strlength(string(opts.ecgQCSaveDir)) == 0
                opts.ecgQCSaveDir = obj.saveDir;
            end

            obj.sourcesToExtract = cellstr(upper(string(opts.sourcesToExtract)));
            if isempty(obj.sourcesToExtract)
                error('Participant:NoSourcesRequested', ...
                    'sourcesToExtract cannot be empty.');
            end

            obj.taskSegmentation = opts.taskSegmentation;
            obj.segmentationProvided = numel(obj.taskSegmentation)>1;

            obj.getData();
            if obj.invalidParticipant; return; end
            obj.setEventArrays();
            obj.preprocessData(opts);
            obj.segmentData();
            obj.extractHrvFeatures();
            if Participant.hasAnySaveEnabled(obj.saveResults)
                obj.save();
            end
        end
        
        function save(obj)

            % Save epoched data
            if obj.saveResults.epochedData
                obj.saveEventData();
            end

            % Save non-segmented data
            if obj.saveResults.nonSegmentedData
                obj.saveNonSegmentedData();
            end

            % Save HRV Features
            if obj.saveResults.features
                obj.saveFeatures();
            end

        end
        
        function getData(obj)
            if isempty(obj.acqParser); obj.getACQParser(); end
            if obj.invalidParticipant; return; end
            if ~isempty(fieldnames(obj.sources)); return; end

            for idx = 1:numel(obj.sourcesToExtract)
                sourceName = char(obj.sourcesToExtract{idx});
                if ~obj.acqParser.hasField(sourceName)
                    warning('getData:MissingSourceChannel', ...
                        'Channel "%s" was requested but is not present. Skipping.', sourceName);
                    continue
                end
                obj.sources.(sourceName) = obj.buildSourceObject(sourceName);
            end
        end
        
        function segmentData(obj)
            if isempty(obj.taskSegmentation); return; end 

            eventArray = obj.acqParser.TTLsummary;
        
            segmenters = struct();          % segmenters.(outField) = Segmenter(...)
            outFields  = {};                % list of outFields we actually created
        
            for sourceIdx = 1:numel(obj.sourcesToExtract)
                sourceName = string(obj.sourcesToExtract(sourceIdx));
                if ~obj.hasSource(sourceName)
                    warning('segmentData:MissingSource', ...
                        'Requested source "%s" not found/empty. Skipping.', sourceName);
                    continue
                end
        
                [seg, outField] = obj.buildSegmenter(sourceName, eventArray);
        
                outField = matlab.lang.makeValidName(char(outField));
                segmenters.(outField) = seg;
                outFields{end+1} = outField; 
            end
        
            for outFieldName = string(outFields)
                obj.epochedData.(outFieldName) = struct();
            end
        
            for taskIdx = 1:numel(obj.taskSegmentation)
                taskName = matlab.lang.makeValidName(obj.taskSegmentation(taskIdx).name);
                eventIds = obj.taskSegmentation(taskIdx).events{1};  
        
                for outfieldIdx = 1:numel(outFields)
                    outfieldName = string(outFields(outfieldIdx));
                    
                    segmenters.(outfieldName).epoch(eventIds);
                    obj.epochedData.(outfieldName).(taskName) = segmenters.(outfieldName).epochs;
                end
            end
        end
        
        function extractHrvFeatures(obj, opts)
            arguments
                obj
                opts.baselineDurationSec (1,1) double = 300
                opts.baselineMethod (1,1) string = "preFirstEvent"
                opts.baselineFallbackMethod (1,1) string = "firstAvailable"
                opts.minDurationForSpectrumSec (1,1) double = 1
                opts.interpHz (1,1) double = 4
            end

            eventArray = [];
            if ~isempty(obj.acqParser)
                eventArray = obj.acqParser.TTLsummary;
            end

            obj.hrvExtractor = HrvFeatureExtractor( ...
                                sources = obj.sources, ...
                                epochedData = obj.epochedData, ...
                                eventArray = eventArray, ...
                                participantId = string(obj.participantId));
            opts = Utils.packStructAsNameValuePairs(opts);
            obj.hrv = obj.hrvExtractor.extract(opts{:});
        end
        
        function tf = hasSource(obj, sourceName)
        
            src = upper(string(sourceName));
        
            try
                switch src
                    case "ECG"
                        tf = isfield(obj.sources, 'ECG') && ...
                             isprop(obj.sources.ECG, 'rri') && ...
                             ~isempty(obj.sources.ECG.rri);
        
                    case "EDA"
                        tf = isfield(obj.sources, 'EDA') && ...
                             isprop(obj.sources.EDA, 'data') && ...
                             ~isempty(obj.sources.EDA.data);
        
                    otherwise
                        % Generic fallback: expects obj.sources.<SRC>.data
                        sField = matlab.lang.makeValidName(char(src));
                        tf = isfield(obj.sources, sField) && ...
                             isprop(obj.sources.(sField), 'data') && ...
                             ~isempty(obj.sources.(sField).data);
                end
            catch
                tf = false;
            end
        end
        
        function [seg, outField] = buildSegmenter(obj, sourceName, eventArray)
            % Creates the correct Segmenter for the given source.
            % outField controls where results land in obj.epochedData.
        
            src = upper(string(sourceName));
        
            switch src
                case "ECG"
                    outField = "RRI";
                    seg = Segmenter( ...
                        'data',             obj.sources.ECG.rri, ...
                        'eventArray',       eventArray, ...
                        'resamplingPeriod', 0.25);
        
                case "EDA"
                    outField = "EDA";
                    seg = Segmenter( ...
                        'data',       obj.sources.EDA.data, ...
                        'eventArray', eventArray);
        
                otherwise
                    % Generic fallback: expects obj.sources.<SRC>.data
                    outField = matlab.lang.makeValidName(char(src));
                    seg = Segmenter( ...
                        'data',       obj.sources.(outField).data, ...
                        'eventArray', eventArray);
            end
        end
    end
    
    methods (Access=private)
        function prepareSaveDirectory(obj)
            [dataDirectory,~,~] = fileparts(obj.participantDataPath);
            obj.saveDir = fullfile(dataDirectory,"..",Participant.saveDirectoryName,string(obj.participantId));
        end

        function getACQParser(obj)
            fprintf("Loading ACQ. of id: %s \n",string(obj.participantId));
            obj.acqParser = ACQParser(obj.participantDataPath,obj.experimentName);
            if ~obj.acqParser.validTTL
                fprintf("Participant %s has invalid TTL codes \n",string(obj.participantId));
                obj.invalidParticipant = true;
                return
            end
        end
        
        function getParticipantId(obj)

            [~, name, ~] = fileparts(obj.participantDataPath);
        
            switch obj.experimentName
                case 'PANDA'
                    % Filename like: 440428.acq
                    obj.participantId = string(name);
        
                case 'ROSES'
                    % Filename like: 102_XX_Physio_S1.acq
                    parts = string(split(name, '_'));
                    obj.participantId = parts(1);
        
                otherwise
                    error('getParticipantId:UnknownExperiment', ...
                        'Unknown experiment type: %s', obj.experimentName);
            end

            obj.participantId = string(obj.participantId);
        
        end

        function saveEventData(obj)
            dataTypeNames = fieldnames(obj.epochedData);
            for dataTypeIndex = 1:numel(dataTypeNames)
                dataTypeName = dataTypeNames{dataTypeIndex};
                obj.saveDataType(dataTypeName);
            end
        end

        function saveDataType(obj, dataTypeName)
            dataTypeStruct = obj.epochedData.(dataTypeName);
            if ~isstruct(dataTypeStruct)
                return
            end
        
            taskNames = fieldnames(dataTypeStruct);
            for taskIndex = 1:numel(taskNames)
                taskName = taskNames{taskIndex};
                obj.saveTask(dataTypeName, taskName);
            end
        end
        
        function saveTask(obj, dataTypeName, taskName)
            dataTypeStruct = obj.epochedData.(dataTypeName);
            if ~isfield(dataTypeStruct, taskName)
                return
            end
        
            dataTable = dataTypeStruct.(taskName);
            if ~istable(dataTable)
                return
            end
        
            dataWriter = DataWriter(data = dataTable, ...
                                    dataType = string(dataTypeName), ...
                                    taskName = string(taskName), ...
                                    participantId = string(obj.participantId));

            dataWriter.save(saveDir = obj.saveDir);
        end

        function saveFeatures(obj)
            if isempty(obj.hrvExtractor) && ~isempty(obj.hrv)
                obj.hrvExtractor = HrvFeatureExtractor(participantId=string(obj.participantId));
                obj.hrvExtractor.hrv = obj.hrv;
            end

            if ~isempty(obj.hrvExtractor)
                obj.hrvExtractor.save(saveDir=obj.saveDir);
            end

        end

        function saveNonSegmentedData(obj)
            sourceSpecs = obj.getNonSegmentedSourceSpecs();
            taskName = "fullRecording";

            for sourceIdx = 1:numel(sourceSpecs)
                sourceSpec = sourceSpecs(sourceIdx);
                if ~isfield(obj.sources, sourceSpec.sourceField)
                    continue
                end

                dataTable = obj.getSourceTableForNonSegmentedSave(sourceSpec);
                [dataTable, isValid] = obj.normalizeNonSegmentedTableForWriting(dataTable, sourceSpec);
                if ~isValid
                    continue
                end

                dataWriter = DataWriter(data = dataTable, ...
                                        dataType = string(sourceSpec.dataType), ...
                                        taskName = taskName, ...
                                        participantId = string(obj.participantId));

                dataWriter.save(saveDir = obj.saveDir);
            end

        end

        function sourceSpecs = getNonSegmentedSourceSpecs(~)
            sourceSpecs = struct( ...
                'sourceField', {'ECG', 'EDA'}, ...
                'sourceProperty', {'rri', 'data'}, ...
                'dataType', {'RRI', 'EDA'}, ...
                'measurementColumn', {'RRI', 'Phasic'});
        end

        function dataTable = getSourceTableForNonSegmentedSave(obj, sourceSpec)
            dataTable = table();

            if ~isfield(obj.sources, sourceSpec.sourceField)
                return
            end

            sourceObject = obj.sources.(sourceSpec.sourceField);
            if ~isprop(sourceObject, sourceSpec.sourceProperty)
                warning('saveNonSegmentedData:MissingSourceProperty', ...
                    'Skipping %s non-segmented save: source property "%s" is unavailable.', ...
                    sourceSpec.sourceField, sourceSpec.sourceProperty);
                return
            end

            dataTable = sourceObject.(sourceSpec.sourceProperty);
        end

        function [dataTable, isValid] = normalizeNonSegmentedTableForWriting(~, dataTable, sourceSpec)
            isValid = false;

            if isempty(dataTable) || ~istable(dataTable)
                warning('saveNonSegmentedData:InvalidDataTable', ...
                    'Skipping %s non-segmented save: expected a non-empty table.', ...
                    sourceSpec.sourceField);
                dataTable = table();
                return
            end

            variableNames = string(dataTable.Properties.VariableNames);
            requiredColumns = ["Timestamp", string(sourceSpec.measurementColumn)];
            missingColumns = requiredColumns(~ismember(requiredColumns, variableNames));
            if ~isempty(missingColumns)
                warning('saveNonSegmentedData:MissingRequiredColumns', ...
                    'Skipping %s non-segmented save: missing required column(s): %s.', ...
                    sourceSpec.sourceField, strjoin(cellstr(missingColumns), ', '));
                dataTable = table();
                return
            end

            numberOfRows = height(dataTable);
            if ~ismember("trial", variableNames)
                dataTable.trial = nan(numberOfRows, 1);
            end
            if ~ismember("eventID", variableNames)
                dataTable.eventID = nan(numberOfRows, 1);
            end

            isValid = true;
        end

        function setEventArrays(obj)
            if isfield(obj.sources,"EDA") && ~isempty(obj.acqParser) && ~isempty(obj.acqParser.TTLsummary)
                obj.sources.EDA.eventArray = obj.acqParser.TTLsummary;
            end
        end
            
        function preprocessData(obj, givenParams)
            arguments
                obj
                givenParams struct = struct()
            end
        
            if obj.isPreProcessed; return; end
        
            for sourceName = string(fieldnames(obj.sources)).'
                srcObject  = obj.sources.(sourceName);

                parametersForThisSource = Utils.getSourceParameters(srcObject,givenParams);
                
                srcObject.preprocess(parametersForThisSource{:});
            end
            
            obj.isPreProcessed = true;
        end

        function inferExperiment(obj)

            [~, name, ~] = fileparts(obj.participantDataPath);
        
            if ~isempty(regexp(name, '^\d+_.*_S\d+$', 'once'))
                % Example: 102_MP_Physio_S1
                obj.experimentName = 'ROSES';
        
            elseif ~isempty(regexp(name, '^\d+$', 'once'))
                % Example: 440428
                obj.experimentName = 'PANDA';
        
            else
                error('inferExperiment:UnknownPattern', ...
                    'Could not infer experiment type from filename: %s', name);
            end
      
        end

        function sourceObject = buildSourceObject(obj, sourceName)
            rawData = obj.acqParser.getField(sourceName);
            samplingFrequency = obj.acqParser.getSamplingFrequency(sourceName);
            try
                sourceObject = feval(sourceName, rawData, struct('fs', samplingFrequency));
            catch
                sourceObject = feval(sourceName, rawData);
            end
        end

    end
    
    methods (Static, Access=private)
        function saveSelection = parseSaveSelection(saveOption)
            if islogical(saveOption) && isscalar(saveOption)
                if saveOption
                    saveSelection = Participant.defaultSaveSelection();
                else
                    saveSelection = Participant.noSaveSelection();
                end
                return
            end

            if isnumeric(saveOption) && isscalar(saveOption) && any(saveOption == [0, 1])
                saveSelection = Participant.parseSaveSelection(logical(saveOption));
                return
            end

            if isstruct(saveOption)
                saveSelection = Participant.parseSaveStruct(saveOption);
                return
            end

            saveTokens = Participant.normalizeSaveTokens(saveOption);
            saveSelection = Participant.selectionFromTokens(saveTokens);
        end

        function saveSelection = parseSaveStruct(saveStruct)
            if ~isscalar(saveStruct)
                error('Participant:InvalidSaveStruct', ...
                    'save struct must be scalar.');
            end
            fields = fieldnames(saveStruct);

            if isempty(fields)
                error('Participant:InvalidSaveStruct', ...
                    'save struct cannot be empty.');
            end

            hasAll = false;
            allValue = false;
            hasNone = false;
            noneValue = false;
            overrideValues = struct( ...
                'epochedData', [], ...
                'nonSegmentedData', [], ...
                'features', []);

            for fieldIdx = 1:numel(fields)
                fieldName = string(fields{fieldIdx});
                fieldValue = saveStruct.(fields{fieldIdx});
                fieldValue = Participant.toLogicalScalar(fieldValue, "save." + fieldName);
                saveKey = Participant.normalizeSaveKey(fieldName);

                switch saveKey
                    case "all"
                        hasAll = true;
                        allValue = fieldValue;
                    case "none"
                        hasNone = true;
                        noneValue = fieldValue;
                    otherwise
                        overrideValues.(char(saveKey)) = fieldValue;
                end
            end

            if hasAll && allValue
                saveSelection = Participant.defaultSaveSelection();
            else
                saveSelection = Participant.noSaveSelection();
            end

            if hasNone && noneValue
                saveSelection = Participant.noSaveSelection();
            end

            if hasAll && hasNone && allValue && noneValue
                error('Participant:InvalidSaveOption', ...
                    'save struct cannot set both "all" and "none" to true.');
            end

            if ~isempty(overrideValues.epochedData)
                saveSelection.epochedData = overrideValues.epochedData;
            end
            if ~isempty(overrideValues.nonSegmentedData)
                saveSelection.nonSegmentedData = overrideValues.nonSegmentedData;
            end
            if ~isempty(overrideValues.features)
                saveSelection.features = overrideValues.features;
            end
        end

        function saveSelection = selectionFromTokens(saveTokens)
            saveKeys = strings(size(saveTokens));
            for tokenIdx = 1:numel(saveTokens)
                saveKeys(tokenIdx) = Participant.normalizeSaveKey(saveTokens(tokenIdx));
            end

            if any(saveKeys == "all")
                saveSelection = Participant.defaultSaveSelection();
                return
            end

            if any(saveKeys == "none")
                if numel(saveKeys) > 1
                    error('Participant:InvalidSaveOption', ...
                        'save cannot contain "none" together with other selections.');
                end
                saveSelection = Participant.noSaveSelection();
                return
            end

            saveSelection = Participant.noSaveSelection();
            for saveKey = saveKeys.'
                saveSelection.(char(saveKey)) = true;
            end
        end

        function saveTokens = normalizeSaveTokens(saveOption)
            if isstring(saveOption)
                saveTokens = saveOption(:);
            elseif ischar(saveOption)
                saveTokens = string({saveOption});
            elseif iscell(saveOption)
                saveTokens = string(saveOption(:));
            else
                error('Participant:InvalidSaveOption', ...
                    'save must be logical, numeric 0/1, a string/list of strings, or a struct.');
            end

            if isempty(saveTokens)
                error('Participant:InvalidSaveOption', ...
                    'save selection cannot be empty.');
            end

            saveTokens = strip(saveTokens);
            if any(saveTokens == "")
                error('Participant:InvalidSaveOption', ...
                    'save selection contains an empty token.');
            end
        end

        function saveKey = normalizeSaveKey(rawKey)
            token = lower(regexprep(string(rawKey), '[\s_\-]', ''));
            switch token
                case {"epoched", "epocheddata", "epoch", "epochs", "eventdata"}
                    saveKey = "epochedData";
                case {"full", "fulldata", "fullrecording", "nonsegmented", "nonsegmenteddata", "continuous"}
                    saveKey = "nonSegmentedData";
                case {"features", "feature", "hrv", "hrvfeatures"}
                    saveKey = "features";
                case "all"
                    saveKey = "all";
                case "none"
                    saveKey = "none";
                otherwise
                    error('Participant:InvalidSaveOption', ...
                        'Unrecognized save selection "%s". Valid values: epoched, full, features, all, none.', ...
                        string(rawKey));
            end
        end

        function value = toLogicalScalar(rawValue, argumentName)
            if islogical(rawValue) && isscalar(rawValue)
                value = rawValue;
                return
            end

            if isnumeric(rawValue) && isscalar(rawValue) && any(rawValue == [0, 1])
                value = logical(rawValue);
                return
            end

            error('Participant:InvalidSaveOption', ...
                '%s must be a logical scalar or numeric 0/1.', argumentName);
        end

        function saveSelection = defaultSaveSelection()
            saveSelection = struct( ...
                'epochedData', true, ...
                'nonSegmentedData', true, ...
                'features', true);
        end

        function saveSelection = noSaveSelection()
            saveSelection = struct( ...
                'epochedData', false, ...
                'nonSegmentedData', false, ...
                'features', false);
        end

        function tf = hasAnySaveEnabled(saveSelection)
            tf = saveSelection.epochedData || ...
                 saveSelection.nonSegmentedData || ...
                 saveSelection.features;
        end
    end
    
end
