classdef Segmenter <handle
    properties
        data
        timeArray
        eventArray
        eventMarker
        epochWindow = [1,4] %s
        bufferTime = 3 %s
        resamplingPeriod = 1/4 %s 1/4 for RRI

        epochs

    end
    
    properties (Access=private)
        dataName
        eventId
        eventSegment
        eventTimestamp
        epochStartTimestamp
        epochEndTimestamp
    end

    methods

        function obj = Segmenter(opts)
            arguments
                opts.data = []
                opts.eventArray = []
                opts.epochWindow = [1,4]
                opts.resamplingPeriod = 0 %s 
            end
            obj.data= opts.data{:,2};
            obj.timeArray = opts.data{:,1};
            obj.dataName = opts.data.Properties.VariableNames{2};
            obj.eventArray = opts.eventArray;
            obj.epochWindow = opts.epochWindow;
            obj.resamplingPeriod = opts.resamplingPeriod;
            
        end

        function epoch(obj, desiredEventIds)
            if iscell(desiredEventIds)
                ids = [desiredEventIds{:}];
            else
                ids = desiredEventIds;
            end
            if ~isnumeric(ids)
                error('desiredEventIds must be a numeric ID, numeric array, or cell array of numeric IDs.');
            end
            ids = unique(ids(:).');
        
            obj.epochs = {};
        
            for id = ids
                obj.eventId=id;
                obj.epochSingleEventId();
            end
        
            if isempty(obj.epochs)
                try
                    obj.epochs = obj.eventSegment([], :);
                catch
                    obj.epochs = table();
                end
            else
                obj.epochs = vertcat(obj.epochs{:});
            end
        end
        
    end

    methods (Access=private)
        function epochSingleEventId(obj)
            filtered = obj.eventArray([obj.eventArray.nid] == obj.eventId);
            if isempty(filtered)
                warning('No events found for eventID=%d. Skipping.', obj.eventId);
                return
            end
            eventTimes = [filtered.time];
            eventName  = filtered(1).name;
            fprintf("Epoching to: %s (ID=%d)\n", eventName, obj.eventId);
            nbEvents = numel(eventTimes);
            for indEvent = 1:nbEvents
                obj.eventTimestamp = eventTimes(indEvent);
                obj.epochSingleEvent();
                obj.eventSegment.trial   = repmat(indEvent, height(obj.eventSegment), 1);
                obj.eventSegment.eventID = repmat(obj.eventId, height(obj.eventSegment), 1);
                obj.epochs{end+1,1} = obj.eventSegment;
            end
        end

        function epochSingleEvent(obj)
            obj.getEventStartEndTimes();
            obj.getEventSegment();
        end
        
        function getEventStartEndTimes(obj)
            obj.epochStartTimestamp = obj.eventTimestamp + obj.epochWindow(1);
            obj.epochEndTimestamp = obj.eventTimestamp + obj.epochWindow(2);
        end

        function getEventSegment(obj)
                    
            if obj.resamplingPeriod~=0
                obj.getEventByInterpolation();
            else    
              
                obj.getEventFromNearestTimestamps();
            end 

            if isempty(obj.eventSegment)
                fs = median(diff(obj.timeArray));
                expectedSegmentTime = (obj.epochStartTimestamp : fs : obj.epochEndTimestamp);
                obj.eventSegment = NaN(2,numel(expectedSegmentTime));
                return; 
            end
            
            obj.eventSegment.Timestamp = seconds(obj.eventSegment.Timestamp - obj.eventSegment.Timestamp(1));
            
            % To keep the Timestamps relative to event
            obj.eventSegment.Timestamp = obj.eventSegment.Timestamp + obj.epochWindow(1);
        end
        
        function getEventFromNearestTimestamps(obj,verbose)
            if nargin<2; verbose = false; end

            % If we don't extract the nearest value, the actual epoch start or end may be offset by up to 1/fs 
            % from the intended timestamp (if the boundary lies just
            % before the next sample).
            % By selecting the nearest sample the maximum offset from
            % the boundary is bounded by 2/fs in total
            idxStart = interp1(obj.timeArray, 1:numel(obj.timeArray), obj.epochStartTimestamp, 'nearest', 'extrap');
            idxEnd   = interp1(obj.timeArray, 1:numel(obj.timeArray), obj.epochEndTimestamp,   'nearest', 'extrap');
            
            eventTimeIndices = false(size(obj.timeArray));
            eventTimeIndices(idxStart:idxEnd) = true;

            timeDuration = seconds(obj.timeArray(eventTimeIndices));
            obj.eventSegment = obj.data(eventTimeIndices, :);
            obj.eventSegment = table(timeDuration,obj.eventSegment,'VariableNames',{'Timestamp',obj.dataName});

            if verbose
                eventTimeIndices = obj.timeArray >= obj.epochStartTimestamp & obj.timeArray<= obj.epochEndTimestamp;
                originalSegment = obj.data(eventTimeIndices, :);
                timeDuration = seconds(obj.timeArray(eventTimeIndices));
                originalSegment = table(timeDuration,originalSegment,'VariableNames',{'Timestamp',obj.dataName});

                obj.plotSingleInterpolatedEvent(originalSegment);
            end

        end

        function getEventByInterpolation(obj,verbose)
            if nargin<2; verbose=false; end
            % Look for a window slightly bigger than what's needed to
            % better interpolate. 
            eventTimeIndices = obj.timeArray >= obj.epochStartTimestamp - obj.bufferTime & obj.timeArray<= obj.epochEndTimestamp + obj.bufferTime;
            obj.eventSegment = obj.data(eventTimeIndices, :);

            newSamplingTimes = seconds(obj.epochStartTimestamp : obj.resamplingPeriod : obj.epochEndTimestamp)';
            
            timeDuration = seconds(obj.timeArray(eventTimeIndices));
            obj.eventSegment = table(timeDuration,obj.eventSegment,'VariableNames',{'Timestamp',obj.dataName});
            obj.eventSegment = table2timetable(obj.eventSegment, 'RowTimes','Timestamp');
            originalSegment = obj.eventSegment;
            obj.eventSegment  = retime(obj.eventSegment, newSamplingTimes, 'spline');
            obj.eventSegment = timetable2table(obj.eventSegment, 'ConvertRowTimes', true);

            if verbose
                obj.plotSingleInterpolatedEvent(originalSegment);
            end
        end

        function plotSingleInterpolatedEvent(obj,originalSegment)
            figure;
            plot(originalSegment.Timestamp,originalSegment.(obj.dataName), ...
                'LineWidth',2, ...
                'DisplayName','Original Signal', ...
                'Marker','^'); 
            hold on; 
            plot(obj.eventSegment.Timestamp,obj.eventSegment.(obj.dataName), ...
                'LineWidth',2, ...
                'DisplayName', ...
                'Interpolated Signal', ...
                'Marker','o');
            xline(seconds(obj.eventTimestamp),'--k', ...
                'LineWidth',2, ...
                'DisplayName','EventTimestamp'); 
            xline(seconds(obj.epochStartTimestamp),'--b', ...
                'LineWidth',2, ...
                'DisplayName','StartEpochWindow');
            xline(seconds(obj.epochEndTimestamp),'--r', ...
                'LineWidth',2, ...
                'DisplayName','EndEpochWindow');
            ylabel(sprintf('%s Signal',obj.dataName));
            legend('show');
            xlabel('Time [s]');
            title('Epoching window');
        end
    end


end