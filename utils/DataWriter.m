classdef DataWriter < handle
    properties (Constant)
    end

    properties
        saveDir
        dataType
        timeBinnedData
        timepointsPerBin = 0 % with 0 it means all timepoints in one bin
        timePerBin = 25 %ms
    end

    properties (Access=protected)
        % Main input data
        data        
        participantId
        taskName

        % Saving parameters
        saveMode
        saveExtension
        
        % Time binning
        timeBinningMode
        timeToBinMapping
        numberOfTimeBins
        timeLabels
        
    end

    methods (Access=public)
        function obj = DataWriter(opts)
            arguments 
                opts.data = []
                opts.dataType = "RRI"
                opts.participantId= ""
                opts.taskName= ""
            end
            
            obj.data = opts.data;
            obj.dataType = opts.dataType;
            obj.participantId = string(opts.participantId);
            obj.taskName = opts.taskName;
            obj.getTimeLabels();
            obj.verifyDataColumns();
        end
        
        function save(obj,opts)
            arguments 
                obj
                opts.saveDir            = ""
                opts.saveMode           = "asParquet"
                opts.timeBinningMode    = "byTimepoints" % {byTimepoints,byTime}
                opts.tPerBin            = 0 % byTimepoints: number of points, byTime: seconds
            end

            obj.saveDir = string(opts.saveDir);
            if strlength(obj.saveDir) == 0
                error('DataWriter:MissingSaveDir', ...
                    'saveDir must be provided when calling DataWriter.save.');
            end
            obj.timeBinningMode = opts.timeBinningMode;

            if ~exist(obj.saveDir, 'dir'); mkdir(obj.saveDir);end
            
            obj.getOutputExtension(opts.saveMode);
            switch obj.saveExtension
                case ".mat"
                    data = obj.data;
                    fileSaveName = NameSchema.format(participantId=obj.participantId, ...
                                                    taskName = obj.taskName, ...
                                                    binningMode = "byTimepoints", ...
                                                    timeBinIdx = 0, ...
                                                    extension = obj.saveExtension, ...
                                                    dataType=obj.dataType);
                    fileSavePath = fullfile(obj.saveDir, fileSaveName);
                    save(fileSavePath, "data", "-v7.3");
                    fprintf("Data has been saved to: %s \n",fileSavePath);
                case {".csv",".parquet"}
                    obj.calculateTimeBinning(opts.tPerBin);
                    obj.iterateTimeBins();
            end

            fprintf("%s %s saving complete.\n",obj.dataType, obj.taskName);

        end

    end
    
    methods (Access=protected)
        function getTimeLabels(obj)
            if size(obj.data,2)>=1
                obj.timeLabels = unique(obj.data.Timestamp);
            end
        end
        
        function verifyDataColumns(obj)
            variableNames = obj.data.Properties.VariableNames;
        
            requiredVariableNames = {'Timestamp', 'trial', 'eventID'};
            for variableIndex = 1:numel(requiredVariableNames)
                variableName = requiredVariableNames{variableIndex};
                if ~ismember(variableName, variableNames)
                    error('verifyDataColumns:MissingColumn', ...
                        'Required column %s is missing from data.', variableName);
                end
            end
        
            switch upper(char(obj.dataType))
                case 'RRI'
                    expectedMeasurementColumnName = 'RRI';
                case 'EDA'
                    expectedMeasurementColumnName = 'Phasic';
                otherwise
                    error('verifyDataColumns:UnsupportedDataType', ...
                        'Unsupported dataType %s.', char(obj.dataType));
            end
        
            if ~ismember(expectedMeasurementColumnName, variableNames)
                error('verifyDataColumns:MissingDataColumn', ...
                    'Required column %s is missing for dataType %s.', ...
                    expectedMeasurementColumnName, char(obj.dataType));
            end
        
            if ~ismember('id', variableNames)
                numberOfRows = height(obj.data);
                obj.data.id = repmat(obj.participantId, numberOfRows, 1);
            end
        
        end

        function getOutputExtension(obj,saveMode)
            if strcmpi(saveMode,"asCSV")
                obj.saveExtension = ".csv";
            elseif strcmpi(saveMode,"asParquet")
                obj.saveExtension = ".parquet";
            elseif strcmpi(saveMode,"asMat")
                obj.saveExtension = ".mat";
            else
                error("Unrecognized save mode %s",saveMode);
            end
        end

        function iterateTimeBins(obj)
            for timeBinIdx = 1:obj.numberOfTimeBins  
                obj.getThisTimeBinData(timeBinIdx);
                
                if isscalar(1:obj.numberOfTimeBins); timeBinIdx = 0; end
                obj.writeBinnedData(timeBinIdx);
                if obj.numberOfTimeBins>1
                    currentBin = timeBinIdx;
                else
                    currentBin = 1;
                end

                DataWriter.updateProgress(round(obj.numberOfTimeBins/10),currentBin,obj.numberOfTimeBins,"Saved", "files");
            end
        end
        
        function writeBinnedData(obj,timeBinIdx)
                                    
            fileSaveName = NameSchema.format(participantId=obj.participantId, ...
                                            taskName = obj.taskName, ...
                                            binningMode = obj.timeBinningMode, ...
                                            timeBinIdx = timeBinIdx, ...
                                            extension = obj.saveExtension, ...
                                            dataType=obj.dataType);
            fileSavePath = fullfile(obj.saveDir,fileSaveName);

            if strcmp(obj.saveExtension,".csv")
                writetable(obj.timeBinnedData,fileSavePath);
                gzip(fileSavePath);            % compress it 
                delete(fileSavePath); 
            elseif strcmp(obj.saveExtension,".parquet")
                parquetwrite(fileSavePath,obj.timeBinnedData);
            end
        end

        function getThisTimeBinData(obj,timeBin)
            mask = ismember(obj.data.Timestamp,obj.timeLabels(obj.timeToBinMapping==timeBin));
            obj.timeBinnedData = obj.data(mask,:);
        end

        function calculateTimeBinning(obj,tPerBin)
            switch obj.timeBinningMode
                case "byTimepoints"
                    obj.timepointsPerBin = tPerBin;
                    timeDatapoints = obj.getTimeDatapoints();
                    if obj.timepointsPerBin ==0
                        obj.timeToBinMapping = ones(timeDatapoints,1);
                    else
                        obj.timeToBinMapping = ceil((1:timeDatapoints)'/obj.timepointsPerBin);
                    end

                case "byTime"
                    obj.timePerBin = tPerBin;
                    if obj.timePerBin <= 0
                        error('DataWriter:InvalidTimePerBin', ...
                            'timePerBin must be > 0 when timeBinningMode is "byTime".');
                    end

                    numericTimeLabels = obj.coerceTimeLabelsToSeconds(obj.timeLabels);
                    tMin = min(numericTimeLabels);
                    tMax = max(numericTimeLabels);
                    edges = tMin : obj.timePerBin : (tMax + obj.timePerBin);
                    obj.timeToBinMapping = discretize(numericTimeLabels, edges);

                    if max(obj.timeToBinMapping)>numel(obj.timeLabels)
                        error("Time binning resulted in more bins than given time labels," + ...
                            " the timePerBin %s s is probably shorter than the spacing between" + ...
                            "the data time labels",obj.timePerBin);
                    end
            end
            obj.numberOfTimeBins = max(obj.timeToBinMapping);
        end

        function timeDatapoints = getTimeDatapoints(obj)
            timeDatapoints = numel(obj.timeLabels);
        end

        function numericTimeLabels = coerceTimeLabelsToSeconds(~, timeLabels)
            if isduration(timeLabels)
                numericTimeLabels = seconds(timeLabels);
            else
                numericTimeLabels = double(timeLabels);
            end
            numericTimeLabels = numericTimeLabels(:);
        end
        
    end
    methods (Static)
        function updateProgress(binSize,currentBin,totalBins,prefixText, suffixText)
            if binSize < 1
                return
            end
            if mod(currentBin,binSize)==0
                fprintf("%s %d / %d %s \n",prefixText,currentBin,totalBins,suffixText);
            end
        end
    end
    
end
