classdef ACQParser < handle
    properties (Constant)
        gapThreshold = 1% datapoints
        defaultSamplingFrequency = 2048
    end
    
    properties
        rawData
        TTLsummary
        validTTL = false

    end

    properties (Access=private)
        dataPath
        uniqueFieldNames
        ttlColumnIndices
        TTLlocations
        decimalTTL
        TTLCodeMapping
        TTLStream=[]
        experimentName
    end

    methods 
        function obj = ACQParser(dataPath,experimentName)
            obj.dataPath = dataPath;
            obj.experimentName = experimentName;
            obj.loadData();
            obj.collectUniqueFieldNames();
            obj.collectTTLSummary();
        end
        
        function fieldData = getField(obj,fieldName)
            fieldName = char(string(fieldName));
            obj.validateFieldName(fieldName);
            fieldIdx = find( strcmp( {obj.rawData.hdr.per_chan_data.comment_text}, fieldName) );
            fieldData = obj.rawData.data(:,fieldIdx);
        end

        function tf = hasField(obj, fieldName)
            fieldName = string(fieldName);
            if isempty(obj.uniqueFieldNames)
                tf = false;
                return
            end
            tf = ismember(fieldName, string(obj.uniqueFieldNames));
        end

        function samplingFrequency = getSamplingFrequency(obj, fieldName)
            samplingFrequency = ACQParser.defaultSamplingFrequency;
            if nargin < 2 || strlength(string(fieldName)) == 0
                return
            end
            if isempty(obj.rawData) || ~isstruct(obj.rawData) || ...
                    ~isfield(obj.rawData, 'hdr') || ~isfield(obj.rawData.hdr, 'samplingRates')
                return
            end

            samplingRates = obj.rawData.hdr.samplingRates;
            if ~istable(samplingRates) || ...
                    ~all(ismember({'name','samplesPerSecond'}, samplingRates.Properties.VariableNames))
                return
            end

            nameMask = strcmpi(string(samplingRates.name), string(fieldName));
            if any(nameMask)
                candidate = samplingRates.samplesPerSecond(find(nameMask, 1, 'first'));
                candidate = double(candidate);
                if isfinite(candidate) && candidate > 0
                    samplingFrequency = candidate;
                end
            end
        end

    end
    
    methods (Access=private)
        
        function collectTTLSummary(obj)
            if ~obj.validTTL; return; end
            
            obj.readTTLStream();
            obj.correctRapidTTLChanges();
            obj.correctSingleZeroBetweenValidTTLs();
            obj.validateTTL();
            if ~obj.validTTL; return; end

            obj.getTTLCodeTable();
            obj.matchTTLCodeNames();
            obj.addOnsetTimeColumn();
            obj.convertTTLTableToStructArray();
        end
        
        function addOnsetTimeColumn(obj)
            samplingFrequency = obj.getSamplingFrequency("Digital input");
            obj.TTLsummary=sortrows(obj.TTLsummary,"onset");
            obj.TTLsummary.time = (obj.TTLsummary.onset-1)/samplingFrequency;
        end

        function convertTTLTableToStructArray(obj)
            % number of events
            nbEvents = height(obj.TTLsummary);
            
            if isstring(obj.TTLsummary.stimuli)
                names = cellstr(obj.TTLsummary.stimuli);
            else
                names = obj.TTLsummary.stimuli; 
            end
            
            % build the struct array
            obj.TTLsummary = struct( ...
                'time',     num2cell(obj.TTLsummary.time), ...
                'nid',      num2cell(obj.TTLsummary.ttl_code), ...
                'name',     names, ...
                'userdata', repmat({[]}, nbEvents, 1) ...
            );
        end

        function validateFieldName(obj,fieldName)
            if  ~ismember(string(fieldName),string(obj.uniqueFieldNames))
                error("Field %s is not in the data",fieldName);
            end
        end

        function collectUniqueFieldNames(obj)
            if ~obj.validTTL; return; end
            obj.uniqueFieldNames = unique({obj.rawData.hdr.per_chan_data.comment_text});
        end

        function loadData(obj)
            readerObject = biopacReader(obj.dataPath);
            obj.rawData = readerObject.readLoadAcq();

            % obj.rawData = load_acq(obj.dataPath);
            obj.validTTL = numel(obj.rawData.data)>0; 
        end
        
        function readTTLStream(obj)
            
            rawTTLCodes = obj.getField("Digital input");
            binWords = logical(rawTTLCodes);
            % obj.TTLStream =  bi2de(binWords,'right-msb');
            obj.TTLStream = bit2int(binWords.',size(binWords,2),false).';
        end
        
        function updateTTLLocationsAndValues(obj)
            obj.TTLlocations = find(any(obj.TTLStream,2));
            obj.decimalTTL = obj.TTLStream(obj.TTLlocations);
        end

        function validateTTL(obj)
            obj.updateTTLLocationsAndValues();
            obj.TTLCodeMapping = ACQParser.readTTLCodeMappingTable(obj.experimentName);
            invalidTTL = ~ismember(obj.decimalTTL, obj.TTLCodeMapping.port);
    
            % Currently invalidating for PANDA because found many ROSES
            % codes that are not present in the reference file
            if ~all(invalidTTL==0) && strcmp(obj.experimentName,"PANDA")
                obj.validTTL = false;
                % error("Found invalid TTLs");
            else
                obj.validTTL = true;
            end

        end
        
        function correctSingleZeroBetweenValidTTLs(obj)
            obj.updateTTLLocationsAndValues();

             % Compute differences between consecutive TTLlocations
            locationDiff = diff(obj.TTLlocations);
            
            % Indices where gap skips one clock cycle
            singleCycleGapIdx = 1+find(locationDiff == 2);

            singleZeroBetweenValidTTLs = obj.TTLlocations(singleCycleGapIdx)-1;
            nextTTLAfterSingleZero = obj.decimalTTL(singleCycleGapIdx);
            obj.TTLStream(singleZeroBetweenValidTTLs) = nextTTLAfterSingleZero;

        end

        function correctRapidTTLChanges(obj)
            obj.updateTTLLocationsAndValues();

            TTLCodeChanges = [true; diff(obj.decimalTTL) ~= 0];
        
            % Identify runs (continuous codes)
            runStarts = find(TTLCodeChanges);
            runEnds   = [runStarts(2:end)-1; length(obj.decimalTTL)];
            runLengths = runEnds - runStarts + 1;
        
            % Transient TTLs are those whose duration is 1 clock cycle
            transientRunIdx = find(runLengths == 1);
            transientTTLidx = obj.TTLlocations(runStarts(transientRunIdx));
            
            nextTTLidxToTransientTTL = obj.TTLlocations(1+runStarts(transientRunIdx));
            distanceFromNextTTLToTransientTTL = nextTTLidxToTransientTTL -transientTTLidx;
            
            % The transientTTLs that come right before the nextTTL are
            % switching into such valid TTL, so they are replaced with it
            transientTTLsSwitchingToValidTTL = distanceFromNextTTLToTransientTTL==1;
            transientTTLsToUpdateWithNextTTL = runStarts(transientRunIdx(transientTTLsSwitchingToValidTTL));
            obj.TTLStream(obj.TTLlocations(transientTTLsToUpdateWithNextTTL)) =  obj.decimalTTL(transientTTLsToUpdateWithNextTTL+1);

            % The transient TTLs that are more than 1 row away from the
            % next TTL were captured when BIOPAC was switching back to zero
            % and need to be dropped 
            transientTTLsSwitchingToZero = ~transientTTLsSwitchingToValidTTL;
            transientTTLsToDrop = runStarts(transientRunIdx(transientTTLsSwitchingToZero));
            obj.TTLStream(obj.TTLlocations(transientTTLsToDrop)) =  0;

        end

        function getTTLCodeTable(obj)
            obj.updateTTLLocationsAndValues();

            % Recompute after fixing transient transitions
            isNewCode = [true; diff(obj.decimalTTL) ~= 0];
            isBigGap  = [false; diff(obj.TTLlocations) > obj.gapThreshold];
            isEventStart = isNewCode | isBigGap;
        
            % Recalculate event indices correctly
            eventStarts = find(isEventStart);
            eventEnds   = [eventStarts(2:end)-1; length(obj.decimalTTL)];
        
            % Calculate timings and durations
            startSamples = obj.TTLlocations(eventStarts);
            endSamples   = obj.TTLlocations(eventEnds);
            codes        = obj.decimalTTL(eventStarts);
            numSamples   = eventEnds - eventStarts + 1;
            samplingFrequency = obj.getSamplingFrequency("Digital input");
            durationSec  = numSamples ./ samplingFrequency;
        
            % Build summary table
            obj.TTLsummary = table( ...
                                codes, ...
                                startSamples, ...
                                endSamples, ...
                                durationSec, ...
                                'VariableNames', ...
                                {'ttl_code','onset','offset','duration_s'} );
        

        end
        
        function matchTTLCodeNames(obj)
            TTLCodeMapping = ACQParser.readTTLCodeMappingTable(obj.experimentName);
            
            obj.TTLsummary = outerjoin( ...
                        obj.TTLsummary, ...
                        TTLCodeMapping, ...
                        'LeftKeys',    'ttl_code', ...
                        'RightKeys',   'port', ...
                        'Type',        'left', ...
                        'RightVariables','stimuli' ...
                    );
            obj.TTLsummary.stimuli = strrep(obj.TTLsummary.stimuli, '_', ' ');
            
        end
    end

    methods (Static)
        function TTLCodeMapping = readTTLCodeMappingTable(experimentName)
            currentFileLocation = fileparts(which("ACQParser"));
            switch experimentName
                case 'PANDA'
                    TTLCodeMappingTablePath = fullfile(currentFileLocation,"panda_ttl_codes.csv");
                    TTLCodeMapping = readtable(TTLCodeMappingTablePath);

                case 'ROSES'
                    TTLCodeMappingTablePath = fullfile(currentFileLocation,"roses_ttl_codes.csv");
                    TTLCodeMapping = readtable(TTLCodeMappingTablePath);
                    TTLCodeMapping.Properties.VariableNames{'TTL_Code_Decimal'} = 'port';
                    TTLCodeMapping.Properties.VariableNames{'TTL_Name'} = 'stimuli';
            end
        end

    end

end
