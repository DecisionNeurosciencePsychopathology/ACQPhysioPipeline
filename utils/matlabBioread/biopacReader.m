%BIOPACREADER High-level MATLAB wrapper for reading BIOPAC ACQ files.
% This MATLAB implementation adapts core reading logic from the Python
% bioread project: https://github.com/njvack/bioread
% Upstream attribution and license text are included in:
% - matlabBioread/COPYRIGHT
% - matlabBioread/LICENSE
classdef biopacReader
    properties (SetAccess = private)
        filePath (1, :) char
        channelIndexes (1, :) double = []
        targetChunkSize (1, 1) double = bioread.DataReader.chunkSize()
    end

    methods
        function obj = biopacReader(filePath, varargin)
            if nargin < 1 || strlength(string(filePath)) == 0
                error('biopacReader:invalidFilePath', 'filePath must be a non-empty path.');
            end

            obj.filePath = char(filePath);

            parser = inputParser;
            parser.addParameter('channelIndexes', [], @(value) isnumeric(value) && isvector(value));
            parser.addParameter('targetChunkSize', bioread.DataReader.chunkSize(), @(value) isnumeric(value) && isscalar(value) && value > 0);
            parser.parse(varargin{:});

            parsedIndexes = unique(parser.Results.channelIndexes(:).');
            if ~isempty(parsedIndexes)
                if any(parsedIndexes < 1) || any(mod(parsedIndexes, 1) ~= 0)
                    error( ...
                        'biopacReader:invalidChannelIndexes', ...
                        'channelIndexes must contain positive integers using MATLAB''s 1-based indexing.' ...
                    );
                end
            end

            obj.channelIndexes = parsedIndexes;
            obj.targetChunkSize = double(parser.Results.targetChunkSize);
        end

        function datafile = read(obj, varargin)
            parser = inputParser;
            parser.addParameter('includeUpsampledData', false, @(value) islogical(value) && isscalar(value));
            parser.addParameter('includeTimeIndex', false, @(value) islogical(value) && isscalar(value));
            parser.parse(varargin{:});

            includeUpsampledData = parser.Results.includeUpsampledData;
            includeTimeIndex = parser.Results.includeTimeIndex;

            datafile = bioread.read(obj.filePath, obj.channelIndexes, obj.targetChunkSize);

            if includeUpsampledData || includeTimeIndex
                datafile = biopacReader.addDerivedChannelData(datafile, includeTimeIndex, includeUpsampledData);
            end
        end

        function loadAcqData = readLoadAcq(obj, varargin)
            try
                datafile = obj.read(varargin{:});
                loadAcqData = biopacReader.toLoadAcqStruct(datafile);

            catch readException
                if strcmp(readException.identifier, 'bioread:unsupportedRevision')
                    try
                        fileRevision = biopacReader.detectFileRevision(obj.filePath);
                    catch
                        rethrow(readException);
                    end

                    if fileRevision == 38
                        loadAcqData = biopacReader.readLoadAcqRevision38(obj.filePath);
                        return;
                    end
                end
                rethrow(readException);
            end
        end
    end

    methods (Static)
        function datafile = readFile(filePath, varargin)
            readerObject = biopacReader(filePath, varargin{:});
            datafile = readerObject.read();
        end
    end

    methods (Static, Access = private)
        function loadAcqData = toLoadAcqStruct(datafile)
            if isfield(datafile, 'channelHeaders')
                channelHeaders = datafile.channelHeaders;
            else
                channelHeaders = struct([]);
            end

            if isfield(datafile, 'channels')
                channels = datafile.channels;
            else
                channels = struct([]);
            end

            hdr = struct('per_chan_data', biopacReader.buildPerChanData(channelHeaders), ...
                'samplingRates', biopacReader.getSamplingRatesTable(datafile));
            channelDataTable = biopacReader.buildChannelDataTable(channels);
            
            loadAcqData = struct( ...
                'hdr', hdr, ...
                'data', channelDataTable ...
            );
        end

        function loadAcqData = readLoadAcqRevision38(filePath)
            if exist('load_acq', 'file') == 0
                error( ...
                    'biopacReader:loadAcqUnavailable', ...
                    ['File revision 38 requires load_acq(filePath), but load_acq.m was not found on the MATLAB path.'] ...
                );
            end

            legacyOutput = load_acq(filePath);
            loadAcqData = biopacReader.normalizeLegacyLoadAcqStruct(legacyOutput);
        end

        function loadAcqData = normalizeLegacyLoadAcqStruct(legacyOutput)
            if ~isstruct(legacyOutput)
                error( ...
                    'biopacReader:loadAcqUnexpectedOutput', ...
                    'load_acq(filePath) for revision 38 must return a struct.' ...
                );
            end

            if isfield(legacyOutput, 'hdr') && isstruct(legacyOutput.hdr)
                hdr = legacyOutput.hdr;
            else
                hdr = struct();
            end

            if isfield(hdr, 'per_chan_data')
                perChanData = hdr.per_chan_data;
            elseif isfield(legacyOutput, 'per_chan_data')
                perChanData = legacyOutput.per_chan_data;
            else
                perChanData = biopacReader.buildPerChanData(struct([]));
            end
            hdr.per_chan_data = perChanData;

            if isfield(legacyOutput, 'data')
                channelData = biopacReader.normalizeLegacyDataMatrix(legacyOutput.data);
            else
                channelData = [];
            end

            loadAcqData = struct( ...
                'hdr', hdr, ...
                'data', channelData ...
            );
        end

        function dataMatrix = normalizeLegacyDataMatrix(rawData)
            if isempty(rawData)
                dataMatrix = [];
                return;
            end

            if isnumeric(rawData) || islogical(rawData)
                dataMatrix = double(rawData);
                return;
            end

            if istable(rawData)
                try
                    tableArray = table2array(rawData);
                    if isnumeric(tableArray) || islogical(tableArray)
                        dataMatrix = double(tableArray);
                        return;
                    end
                catch
                end
                rawData = table2cell(rawData);
            end

            if iscell(rawData)
                if all(cellfun(@(value) isnumeric(value) && isscalar(value), rawData(:)))
                    dataMatrix = double(cell2mat(rawData));
                    return;
                end

                if ~isvector(rawData)
                    error( ...
                        'biopacReader:loadAcqUnexpectedOutput', ...
                        'load_acq(filePath) returned cell data that could not be converted to a numeric matrix.' ...
                    );
                end

                channelCount = numel(rawData);
                channelLengths = cellfun(@numel, rawData);
                maxLength = max(channelLengths);
                dataMatrix = NaN(maxLength, channelCount);

                for channelIndex = 1:channelCount
                    channelValues = rawData{channelIndex};
                    if ~(isnumeric(channelValues) || islogical(channelValues))
                        error( ...
                            'biopacReader:loadAcqUnexpectedOutput', ...
                            'load_acq(filePath) returned non-numeric channel data.' ...
                        );
                    end

                    channelValues = double(channelValues(:));
                    dataMatrix(1:numel(channelValues), channelIndex) = channelValues;
                end
                return;
            end

            error( ...
                'biopacReader:loadAcqUnexpectedOutput', ...
                'load_acq(filePath) returned data of class "%s"; expected numeric, table, or cell.', ...
                class(rawData) ...
            );
        end

        function fileRevision = detectFileRevision(filePath)
            [acqFileId, openMessage] = fopen(filePath, 'rb');
            if acqFileId < 0
                error('biopacReader:openFailed', 'Could not open "%s": %s', filePath, openMessage);
            end
            fileCloser = onCleanup(@() fclose(acqFileId)); %#ok<NASGU>

            fseek(acqFileId, 2, 'bof');
            revisionLittle = fread(acqFileId, 1, 'uint32=>uint32', 0, 'ieee-le');
            fseek(acqFileId, 2, 'bof');
            revisionBig = fread(acqFileId, 1, 'uint32=>uint32', 0, 'ieee-be');

            if isempty(revisionLittle) || isempty(revisionBig)
                error('biopacReader:unexpectedEof', 'Unexpected end-of-file while reading file revision.');
            end

            fileRevision = double(min([revisionLittle, revisionBig]));
        end

        function perChanData = buildPerChanData(channelHeaders)
            template = struct( ...
                'chan_header_len', [], ...
                'num', [], ...
                'comment_text', '', ...
                'rgb_color', [], ...
                'disp_chan', [], ...
                'volt_offset', [], ...
                'volt_scale', [], ...
                'units_text', '', ...
                'buf_length', [], ...
                'ampl_scale', [], ...
                'ampl_offset', [], ...
                'chan_order', [], ...
                'disp_size', [], ...
                'plot_mode', [], ...
                'mid', [], ...
                'description', '', ...
                'var_sample_divider', [] ...
            );

            channelCount = numel(channelHeaders);
            if channelCount == 0
                perChanData = repmat(template, 0, 1);
                return;
            end

            perChanData = repmat(template, channelCount, 1);
            for channelIndex = 1:channelCount
                header = channelHeaders(channelIndex);

                if isfield(header, 'name')
                    perChanData(channelIndex).comment_text = biopacReader.simplifyCommentText(header.name);
                end
                if isfield(header, 'units')
                    perChanData(channelIndex).units_text = header.units;
                end
                if isfield(header, 'rawScale')
                    perChanData(channelIndex).ampl_scale = header.rawScale;
                end
                if isfield(header, 'channelNumber')
                    perChanData(channelIndex).chan_order = header.channelNumber;
                end
            end
        end

        function samplingRatesTable = getSamplingRatesTable(datafile)

            datafileChannels = datafile.channels;
            
            channelNamesOriginal = {datafileChannels.name}.';
            channelSamplesPerSecond = [datafileChannels.samplesPerSecond].';
            
            channelNamesSimplified = string(cellfun( ...
                @(nameValue) biopacReader.simplifyCommentText(nameValue), ...
                cellstr(channelNamesOriginal), ...
                'UniformOutput', false));
            
            samplingRatesTable = table(channelNamesSimplified, channelSamplesPerSecond, ...
                'VariableNames', {'name','samplesPerSecond'});
            
        end

        function commentText = simplifyCommentText(rawCommentText)
            sourceText = string(rawCommentText);
            sourceText = sourceText(:);
            if isempty(sourceText)
                commentText = '';
                return;
            end
            sourceText = strtrim(sourceText(1));

            if strlength(sourceText) == 0
                commentText = '';
                return;
            end

            lowerText = lower(sourceText);

            if contains(lowerText, 'digital input')
                commentText = 'Digital input';
                return;
            end

            if contains(lowerText, 'ecg') || contains(lowerText, 'ekg')
                commentText = 'ECG';
                return;
            end

            if contains(lowerText, 'eda')
                commentText = 'EDA';
                return;
            end

            if contains(lowerText, 'icg')
                if ~isempty(regexp(lowerText, 'd\s*z\s*/\s*d\s*t', 'once'))
                    commentText = 'ICG dZ/dt';
                    return;
                end

                if ~isempty(regexp(lowerText, '(^|[^a-z])z([^a-z]|$)', 'once'))
                    commentText = 'ICG Z';
                    return;
                end

                commentText = 'ICG';
                return;
            end

            commentText = char(sourceText);
        end

        function channelDataTable = buildChannelDataTable(channels)
            channelCount = numel(channels);
            if channelCount == 0
                channelDataTable = [];
                return;
            end

            nCh = numel(channels);            
            lens = arrayfun(@(s) numel(s.data), channels);
            N = max(lens);
            
            channelDataTable = NaN(N, nCh);
            
            for i = 1:nCh
                v = channels(i).data(:);          % make it a column
                channelDataTable(1:numel(v), i) = v;
            end
                        
        end

        function variableNames = channelVariableNames(channels)
            channelCount = numel(channels);
            baseNames = cell(1, channelCount);

            for channelIndex = 1:channelCount
                channelName = '';
                if isfield(channels(channelIndex), 'name')
                    channelName = channels(channelIndex).name;
                end

                if strlength(string(channelName)) == 0
                    baseNames{channelIndex} = sprintf('feature_%d', channelIndex);
                else
                    baseNames{channelIndex} = char(channelName);
                end
            end

            variableNames = matlab.lang.makeValidName(baseNames, 'ReplacementStyle', 'delete');
            for channelIndex = 1:channelCount
                if strlength(string(variableNames{channelIndex})) == 0
                    variableNames{channelIndex} = sprintf('feature_%d', channelIndex);
                end
            end
            variableNames = matlab.lang.makeUniqueStrings(variableNames);
        end

        function datafile = addDerivedChannelData(datafile, includeTimeIndex, includeUpsampledData)
            channels = datafile.channels;
            totalSamples = biopacReader.computeTotalSamples(channels);

            if includeTimeIndex && totalSamples > 0
                totalSeconds = totalSamples / datafile.samplesPerSecond;
                datafile.timeIndex = linspace(0, totalSeconds, totalSamples);
            else
                datafile.timeIndex = [];
            end

            for channelIndex = 1:numel(channels)
                channelData = channels(channelIndex);

                if includeTimeIndex && ~isempty(datafile.timeIndex)
                    channelTimeIndex = datafile.timeIndex(1:channelData.frequencyDivider:end);
                    channels(channelIndex).timeIndex = channelTimeIndex(1:min(numel(channelTimeIndex), channelData.pointCount));
                else
                    channels(channelIndex).timeIndex = [];
                end

                if includeUpsampledData && ~isempty(channelData.data)
                    upsampledLength = numel(channelData.data) * channelData.frequencyDivider;
                    upsampleIndexes = floor((0:(upsampledLength - 1)) ./ channelData.frequencyDivider) + 1;
                    upsampleIndexes = min(upsampleIndexes, numel(channelData.data));
                    channels(channelIndex).upsampledData = channelData.data(upsampleIndexes);
                else
                    channels(channelIndex).upsampledData = [];
                end
            end

            datafile.channels = channels;
            datafile = bioread.Reader.refreshDatafileCaches(datafile);
        end

        function totalSamples = computeTotalSamples(channels)
            if isempty(channels)
                totalSamples = 0;
                return;
            end

            totalSamples = max([channels.frequencyDivider] .* [channels.pointCount]);
        end
    end
end
