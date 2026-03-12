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
        
        function preprocess(obj)
            if obj.isPreprocessed; return; end
            obj.runLedalabAnalysis();
            obj.isPreprocessed = true;
        end
        
        function runLedalabAnalysis(obj,tempSaveDir)
            if nargin<2; tempSaveDir = "./PreprocessedEDA"; end
            obj.tempSaveDir = tempSaveDir;
            obj.prepareTemporalSavingPath();
            obj.saveForLedalabAnalysis();
            obj.processWithLedalab();
            obj.deleteTemporalFile();
        end
        
        function processWithLedalab(obj)
            if exist('Ledalab', 'file') ~= 2
                error('EDA:MissingLedalabDependency', ...
                    ['Ledalab was not found on the MATLAB path. ', ...
                     'Install/add Ledalab before running EDA preprocessing.']);
            end
            % 
            Ledalab( char(obj.tempFilePath), ...
                     'open',     'mat', ...    % load .mat
                     'filter',[1,EDA.highCutoffFrequency],...
                     'downsample',obj.downsamplingFactor,...
                     'smooth',     {'gauss', round(EDA.medianSmoothingWindow * obj.downsamplingFs)},      ... 
                     'analyze',  'CDA', ...    % Continuous Decomposition
                     'optimize', 1 );          % fit model parameters
            obj.fs = obj.downsamplingFs;
            global leda2 
            obj.ledaStruct = leda2;
            obj.timeArray = obj.ledaStruct.data.time.data;
            obj.phasicData = obj.ledaStruct.analysis.phasicData;
            obj.data = table(obj.timeArray',obj.phasicData','VariableNames',{'Timestamp','Phasic'});

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
       
    end
    
    methods(Static)
        function p = getDefaultPreprocessParams()
            p = struct();
        end
    end
end
