classdef ECG <handle
    properties(Constant)
        lowCutoffFrequency = 0.5 %Hz
        highCutoffFrequency = 40 %Hz
        lowerLimitHR = 40 %bpm
        ECGSensorLimit = 1500
        lowLimitRRI = 462 %130 bpm
        highLimitRRI = 1200 % 50bpm
        fnotch = 60 % line frequency (Hz)
    end

    properties
        data
        rri
        rriRaw
        rriReviewed
        ecgTimestamps
        fs= 2048 % Hz
        id =0
        peaksRawIdx
        peaksReviewedIdx

    end

    properties (Access=private)
        isPreprocessed = false
        isFiltered = false
        artifactRejectionService
    end

    methods
        function obj = ECG(rawData, opts)
            if nargin < 2 || isempty(opts)
                opts = struct();
            end
            obj.data = rawData;
            if isfield(opts, 'fs')
                samplingFrequency = double(opts.fs);
                if isfinite(samplingFrequency) && samplingFrequency > 0
                    obj.fs = samplingFrequency;
                end
            end
            obj.artifactRejectionService = ECGRriArtifactRejectionService();

        end
        
        function preprocess(obj,opts)
            arguments
                obj
                opts.ecgArtifactRejectionMethod = "trim" % {trim,ignore,manual,semiauto}
                opts.ecgQCSaveDir = ""
                opts.verbose = false
            end

            if obj.isPreprocessed; return; end
            
            % obj.filter(); 
            obj.ensurePanTompkinsAvailable();
            opts.ecgArtifactRejectionMethod =lower(opts.ecgArtifactRejectionMethod);
            manualMode = strcmp(opts.ecgArtifactRejectionMethod, "manual") || ...
                strcmp(opts.ecgArtifactRejectionMethod, "semiauto") || ...
                strcmp(opts.ecgArtifactRejectionMethod, "semiautomatic");
            obj.computeRRIwithPanTompkins(opts.verbose | manualMode);
            obj.runArtifactRejection(opts);
            obj.isPreprocessed = true;
        end   
    end

    methods (Access=private)

        function computeRRIwithPanTompkins(obj,verbose)
            
            % if verbose
            %     obj.plotOutsideThreshold(ECG.getTimeVector(numel(obj.data),obj.fs)', ...
            %                             obj.data,'ECG');
            % end

            rawData = obj.data;
            mask = rawData <= ECG.ECGSensorLimit & rawData >= -ECG.ECGSensorLimit; % Drop values outside expected sensor range (heuristically obtained)
            obj.data = rawData(mask);
            timestamps = ECG.getTimeVector(numel(rawData), obj.fs)';
            timestamps = timestamps(mask);
            obj.ecgTimestamps = timestamps(:);
            clear mask rawData;

            if isempty(obj.data)
                error('ECG:NoValidSamples', ...
                    'No ECG samples remain after applying ECGSensorLimit filtering.');
            end

            plottingNeeded = logical(verbose);
            disp("Running Pan Tompkins algorithm to find QRS peaks")
            [~,estimatedPeakIndices,~] = pan_tompkin(obj.data,obj.fs,false);%,plottingNeeded);
            disp("Peaks found");

            refinedPeakIndices = obj.refinePeakLocationsUsingRawEcg(obj.data, estimatedPeakIndices, obj.fs);
            obj.peaksRawIdx = refinedPeakIndices(:);

            obj.rri = ECG.getRRITableFromPeakLocations(timestamps,refinedPeakIndices);
            if isempty(obj.rriRaw)
                obj.rriRaw = obj.rri;
            end
            % if verbose 
            %     obj.plotOutsideThreshold(obj.rriRaw.Timestamp, ...
            %                             obj.rriRaw.RRI,'RRI')
            % end

        end
        
        function refinedPeakIndices = refinePeakLocationsUsingRawEcg(~, rawEcgSignal, estimatedPeakIndices, samplingFrequency)
            if isempty(estimatedPeakIndices)
                refinedPeakIndices = estimatedPeakIndices(:);
                return
            end

            referencePeakIndices = estimatedPeakIndices(:);
            searchWindowRadiusInSamples = round(0.05 * samplingFrequency);
            totalSignalSamples = numel(rawEcgSignal);
            refinedPeakIndices = zeros(size(referencePeakIndices));

            for peakCounter = 1:numel(referencePeakIndices)
                referencePeakIndex = referencePeakIndices(peakCounter);
                searchWindowStartIndex = max(1, referencePeakIndex - searchWindowRadiusInSamples);
                searchWindowEndIndex = min(totalSignalSamples, referencePeakIndex + searchWindowRadiusInSamples);
                [~, peakOffsetWithinWindow] = max(rawEcgSignal(searchWindowStartIndex:searchWindowEndIndex));
                refinedPeakIndices(peakCounter) = searchWindowStartIndex + peakOffsetWithinWindow - 1;
            end
        end

        function filter(obj)
            if obj.isFiltered; return; end
            Q  = 35;             % quality factor 
            
            % normalized notch frequency
            wo = obj.fnotch/(obj.fs/2);
            bw = wo/Q;
        
            % design a second-order notch filter
            [b, a] = iirnotch(wo, bw);
        
            % apply zero-phase filtering to avoid phase distortion
            obj.data = filtfilt(b, a, obj.data);
            
            obj.isFiltered = true;

        end

        function rriData = computeRriFromPeaks(obj, peaksIdx)
            if isempty(peaksIdx)
                rriData = table([], [], 'VariableNames', {'Timestamp','RRI'});
                return
            end
            timestamps = obj.getWorkingTimestamps();
            rriData = ECG.getRRITableFromPeakLocations(timestamps, peaksIdx);
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

        function plotOutsideThreshold(obj,timestamps,data,source)
            switch source
                case "RRI"
                    lowLimit= ECG.lowLimitRRI;
                    highLimit= ECG.highLimitRRI;
                    ylabelText= 'RRI [ms]';
                    plotTitle = 'RRIs outside of range';               
                case "ECG"
                    lowLimit= -ECG.ECGSensorLimit;
                    highLimit= ECG.ECGSensorLimit;
                    ylabelText= 'ECG [\muV]';
                    plotTitle = 'ECG outside limit';
            end

            lowerLimitMask = data < lowLimit;
            highLimitMask = data> highLimit;
        
            outsideLimitPoints = [find(lowerLimitMask);find(highLimitMask)];
            windowAroundArea = 10;
            if numel(outsideLimitPoints)<1
                return
            end

            windowAroundPointsOutsideThreshold = ECG.mergeWindows(outsideLimitPoints, windowAroundArea);

            for i=1:size(windowAroundPointsOutsideThreshold,1)
                startPoint = max(windowAroundPointsOutsideThreshold(i,1),1);
                endPoint = min(windowAroundPointsOutsideThreshold(i,2),length(timestamps));
                
                timeAxis = timestamps(startPoint:endPoint);
                highLimitLine = highLimit * ones(length(timeAxis),1);
                lowLimitLine = lowLimit * ones(length(timeAxis),1);
                
                hFig = figure('Color','w');            
                hAx  = axes('Parent',hFig);

                plot(hAx,timeAxis,data(startPoint:endPoint),'LineWidth',3,'DisplayName','RRI');
                hold on;
                plot(hAx,timeAxis,highLimitLine,'--r','DisplayName','high limit');
                plot(hAx,timeAxis,lowLimitLine,'--r','DisplayName','low limit');

                xlabel(hAx,'Time [s]', 'FontSize', 20);
                ylabel(hAx,ylabelText, 'FontSize', 20);
                title(hAx,plotTitle, 'FontSize', 20);
                % subtitle(hAx,sprintf('Participant %s',string(obj.id)),"FontSize",15);
                if strcmp(source,'RRI')
                    ecgTimes = ECG.getTimeVector(numel(obj.data),obj.fs)';
                    [~, idx] = ismember(timeAxis, ecgTimes);
                    yyaxis right;
                    ecgStartPoint = idx(1);
                    ecgEndPoint = idx(end);
                    plot(hAx,ecgTimes(ecgStartPoint:ecgEndPoint),obj.data(ecgStartPoint:ecgEndPoint),'Color','k','DisplayName','ECG');
                    ylabel(hAx,'ECG [\muV]');

                end

                box(hAx, 'off');
                set(hAx, 'TickDir', 'out');
                set(hAx, 'LineWidth', 1.2);
                set(hAx, 'FontSize', 20);
                grid(hAx, 'on');
                hAx.GridColor = [0.8 0.8 0.8];
                hAx.GridAlpha = 0.5;
                hAx.Layer = 'bottom';
                legend(hAx, {'RRI','High limit','Low limit','ECG'}, ...
                   'Location',    'northeast', ...
                   'FontSize',    14, ...
                   'Box',         'off');
            end 
        end
    
        function runArtifactRejection(obj, opts)
            obj.ensureArtifactRejectionService();

            timestamps = obj.getWorkingTimestamps();
            ecgData = table(obj.data, timestamps(:), 'VariableNames', {'ECG','Timestamp'});

            state = struct( ...
                'sourceECG', ecgData, ...
                'rriRaw', obj.rriRaw, ...
                'peaksRawIdx', obj.peaksRawIdx, ...
                'rri', obj.rri, ...
                'lowLimitRRI', ECG.lowLimitRRI, ...
                'highLimitRRI', ECG.highLimitRRI, ...
                'fs', obj.fs, ...
                'computeRriFromPeaksFcn', @(x)obj.computeRriFromPeaks(x));

            result = obj.artifactRejectionService.run(state, opts);
            obj.rri = result.rri;
            obj.rriRaw = result.rriRaw;
            obj.peaksRawIdx = result.peaksRawIdx;
            if isfield(result, 'peaksReviewedIdx')
                obj.peaksReviewedIdx = result.peaksReviewedIdx;
            end
        end
        
        function ensureArtifactRejectionService(obj)
            if isempty(obj.artifactRejectionService) || ~isvalid(obj.artifactRejectionService)
                obj.artifactRejectionService = ECGRriArtifactRejectionService();
            end
        end

        function timestamps = getWorkingTimestamps(obj)
            if ~isempty(obj.ecgTimestamps) && numel(obj.ecgTimestamps) == numel(obj.data)
                timestamps = obj.ecgTimestamps(:);
            else
                timestamps = ECG.getTimeVector(numel(obj.data), obj.fs)';
            end
        end

        function ensurePanTompkinsAvailable(~)
            if exist('pan_tompkin', 'file') ~= 2
                error('ECG:MissingPanTompkinsDependency', ...
                    ['Function pan_tompkin.m was not found on the MATLAB path. ', ...
                     'Install/add Pan-Tompkins dependency before running ECG preprocessing.']);
            end
        end


    end

    methods (Static)

        function timeVector = getTimeVector(pointsInVector,fs)
            timeVector = 0 : 1/fs : 1/fs*(pointsInVector-1);
        end  
        
        function rriData = getRRITableFromPeakLocations(timestamps,ind_locs)
            locs = timestamps(ind_locs); % Using the indices to get the actual locations
            rri = diff(locs)*1e3; % in ms
        
            % Organizing into table
            rri_timestamp = locs(2:end);
            rriData = table(rri_timestamp,rri,'VariableNames',{'Timestamp','RRI'});
        end
        
        function merged = mergeWindows(points, w)
                        
                % sort points and build start/end for each
                points   = sort(points(:));
                starts = points - w;
                ends   = points + w;
                
                % now merge overlapping intervals
                merged = [];
                previousWindow    = [starts(1), ends(1)];
                for k = 2:numel(points)
                    s = starts(k);
                    e = ends(k);
                    if s <= previousWindow(2)          % overlap or touching
                        previousWindow(2) = max(previousWindow(2), e);
                    else
                        merged = [merged; previousWindow]; %#ok<AGROW>
                        previousWindow    = [s, e];
                    end
                end
                merged = [merged; previousWindow];                
            end
        
        function p = getDefaultPreprocessParams()
            p = struct('ecgArtifactRejectionMethod','trim','ecgQCSaveDir',"",'verbose',false);
        end

    end

end
