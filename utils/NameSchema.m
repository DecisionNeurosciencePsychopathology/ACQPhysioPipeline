classdef NameSchema
    properties (Constant)
        DEFAULT_EXT = ".parquet";
    end

    methods (Static)
        function fileName = format(opts)
            arguments
                opts.participantId   = "123456"
                opts.taskName       = "feedback"
                opts.binningMode     = "byTimepoints"
                opts.timeBinIdx      = 0
                opts.extension       = NameSchema.DEFAULT_EXT
                opts.asPattern       = false
                opts.dataType        = "RRI"
            end

            timeBinLabel = NameSchema.validateTimeBinningMode(opts.binningMode);

            if opts.asPattern
                fmt  = "%s";
                args = { opts.dataType, opts.taskName };
            else
                fmt  = "%s_%s_%s";
                args = { opts.participantId,opts.dataType, opts.taskName };
            end

            if opts.timeBinIdx > 0
                fmt = fmt + "_%s_%03d%s";
                args{end+1} = timeBinLabel;
                args{end+1} = opts.timeBinIdx;
                args{end+1} = opts.extension;
            else
                fmt = fmt + "%s";
                args{end+1} = opts.extension;
            end

            fileName = sprintf(fmt, args{:});
        end

        function meta = parse(fileName, varargin)
            p = inputParser;
            addParameter(p, 'AssumePattern', false, @(x)islogical(x)||ismember(x,[0 1]));
            parse(p, varargin{:});
            assumePattern = logical(p.Results.AssumePattern);

            [~, base, ext] = fileparts(fileName);
            if ~strcmpi(ext, NameSchema.DEFAULT_EXT)
                error('NameSchema:Extension', ...
                    'File "%s" does not have "%s" extension.', fileName, NameSchema.DEFAULT_EXT);
            end

            parts  = split(string(base), "_");
            nParts = numel(parts);
            if nParts < 1
                error('NameSchema:BadFormat', ...
                    'Filename "%s" has too few underscore-separated parts.', fileName);
            end

            timeBinIdx   = 0;
            timeBinLabel = "";
            tailSpan     = 0;

            if nParts >= 2
                numericIndex = str2double(parts(end));
                if ~isnan(numericIndex)
                    timeBinIdx   = numericIndex;
                    timeBinLabel = parts(end-1);
                    tailSpan     = 2;
                end
            end

            baseEndIndex = nParts - tailSpan;
            if baseEndIndex <= 0
                error('NameSchema:BadFormat', ...
                    'Filename "%s" does not contain any base name parts.', fileName);
            end

            if assumePattern
                participantId = "";
                eventTokens   = parts(1:baseEndIndex);
            else
                if baseEndIndex < 2
                    error('NameSchema:BadFormat', ...
                        'Filename "%s" does not contain participant and event parts.', fileName);
                end
                participantId = parts(1);
                eventTokens   = parts(2:baseEndIndex);
            end

            eventName = strjoin(eventTokens, "_");

            meta = struct();
            meta.fileName      = fileName;
            meta.extension     = ext;
            meta.participantId = participantId;
            meta.eventName     = eventName;

            meta.section       = "";
            meta.blockBinIdx   = 0;
            meta.channelLabel  = "";

            meta.dataType      = "RRI";
            meta.timeBinLabel  = timeBinLabel;
            meta.timeBinIdx    = timeBinIdx;
            meta.freqBinLabel  = "";
            meta.freqBinIdx    = NaN;

            meta.binningMode = NameSchema.inferBinningMode(meta.timeBinLabel);

            meta.patternKey = char(strjoin([ ...
                string(meta.participantId), ...
                string(meta.eventName), ...
                string(meta.timeBinLabel), ...
                string(meta.dataType)], "|"));
        end

        function rx = regex(kind)
            arguments
                kind string = "any"
            end
            timeAltCore = "tpBin|tBin|byTimepoints|byTime|time|timeBin|timepoints";
            head    = "(?<participantId>[^_]+)_(?<eventName>[^_]+)";
            headAlt = "(?<eventName>[^_]+)";
            tail    = "(?:_(?<timeBinLabel>(" + timeAltCore + "))_(?<timeBinIdx>\d{1,}))?";
            ext     = "\.parquet$";

            core = "(?:" + head + "|" + headAlt + ")" + tail;
            rx   = "^" + core + ext;
        end

        function roundTripAssert(fileName)
            m1 = NameSchema.parse(fileName);
            opts = NameSchema.buildOptsFromMeta(m1);
            f2 = NameSchema.format(opts);
            m2 = NameSchema.parse(f2);
            same = isequaln( rmfield(m1, {'fileName'}), rmfield(m2, {'fileName'}) );
            if ~same
                error('NameSchema:RoundTrip', 'Round-trip mismatch:\n  in : %s\n  out: %s', fileName, f2);
            end
        end

        function opts = buildOptsFromMeta(meta)
            opts = struct();
            opts.participantId = string(meta.participantId);
            opts.eventName     = string(meta.eventName);
            opts.binningMode   = string(meta.binningMode);
            opts.timeBinIdx    = double(meta.timeBinIdx);
            opts.extension     = NameSchema.DEFAULT_EXT;
            opts.asPattern     = (opts.participantId == "");
            opts.dataType      = string(meta.dataType);
        end

        function participantId = validateParticipantId(fileName)
            digitsOnly = regexprep(fileName, '[^0-9]', '');
            if numel(char(digitsOnly)) >= 5 && numel(char(digitsOnly)) <= 6
                participantId = string(digitsOnly);
            else
                participantId = "";
            end
        end

        function binningMode = validateBinningMode(binningMode)
            if isa(binningMode,'string')
                binningMode = char(binningMode);
            end
            if ~ischar(binningMode)
                error('validateSavingMode:InvalidType', ...
                    'saveMode must be a character vector or string scalar.');
            end

            binningMode = strtrim(binningMode);

            if ~isempty(regexp(binningMode, '^(?:by)?timepoints$', 'ignorecase'))
                binningMode = 'byTimepoints';
            elseif ~isempty(regexp(binningMode, '^(?:by)?time$', 'ignorecase'))
                binningMode = 'byTime';
            else
                error('validateSavingMode:InvalidValue', ...
                    'Invalid save mode "%s". Valid options are "byTime" or "byTimepoints" (case‐insensitive).', ...
                    binningMode);
            end
        end

        function saveMode = validateSavingMode(saveMode)
            if isa(saveMode, 'string')
                saveMode = char(saveMode);
            end
            if ~ischar(saveMode)
                error('validateExportMode:InvalidType', ...
                    'exportMode must be a character vector or string scalar.');
            end

            saveMode = strtrim(saveMode);

            if ~isempty(regexp(saveMode, '^(?:as)?mat$', 'ignorecase'))
                saveMode = 'asMat';
            elseif ~isempty(regexp(saveMode, '^(?:as)?csv$', 'ignorecase'))
                saveMode = 'asCSV';
            elseif ~isempty(regexp(saveMode, '^(?:as)?parquet$', 'ignorecase'))
                saveMode = 'asParquet';
            else
                error('validateExportMode:InvalidValue', ...
                    'Invalid export mode "%s". Valid options are "asMat", "asCSV", or "asParquet" (case‐insensitive).', ...
                    saveMode);
            end
        end

        function frequencyString = validateFrequencyLabel(frequencyLabel)
            if isnumeric(frequencyLabel)
                frequencyString = sprintf('%02d', frequencyLabel);
            else
                frequencyString = char(frequencyLabel);
            end
        end
    end

    methods (Static, Access = private)
        function timeBinLabel = validateTimeBinningMode(timeBinningMode)
            timeBinningMode = lower(string(timeBinningMode));
            if strcmp(timeBinningMode,"bytimepoints")
                timeBinLabel = "tpBin";
            elseif strcmp(timeBinningMode,"bytime")
                timeBinLabel = "tBin";
            else
                error('NameSchema:InvalidBinningMode', ...
                    'Invalid binning mode "%s".', timeBinningMode);
            end
        end

        function mode = inferBinningMode(timeBinLabel)
            lbl = lower(char(string(timeBinLabel)));
            if contains(lbl, "tpbin") || contains(lbl, "timepoints")
                mode = "byTimepoints";
            elseif contains(lbl, "tbin") || contains(lbl, "timebin") || contains(lbl, "time")
                mode = "byTime";
            else
                mode = "";
            end
        end
    end
end
