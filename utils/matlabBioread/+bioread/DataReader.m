classdef DataReader < handle
    properties
        acqFileId (1, 1) double
        datafile struct
        dataStartOffset (1, 1) double
        fileRevision (1, 1) double
        byteOrderChar (1, 1) char
    end

    methods (Static)
        function value = chunkSize()
            value = 1024 * 256;
        end
    end

    methods
        function this = DataReader(acqFileId, datafile, dataStartOffset, fileRevision, byteOrderChar)
            this.acqFileId = acqFileId;
            this.datafile = datafile;
            this.dataStartOffset = dataStartOffset;
            this.fileRevision = fileRevision;
            this.byteOrderChar = byteOrderChar;
        end

        function datafile = readData(this, channelIndexes, targetChunkSize)
            if nargin < 2
                channelIndexes = [];
            end
            if nargin < 3 || isempty(targetChunkSize)
                targetChunkSize = bioread.DataReader.chunkSize();
            end

            if this.datafile.isCompressed
                datafile = this.readDataCompressed(channelIndexes);
            else
                datafile = this.readDataUncompressed(channelIndexes, targetChunkSize);
            end
        end

        function datafile = readDataCompressed(this, channelIndexes)
            channels = this.datafile.channels;
            channelCount = numel(channels);
            selectedIndexes = bioread.DataReader.normalizeChannelIndexes(channelIndexes, channelCount);
            selectedMask = false(1, channelCount);
            selectedMask(selectedIndexes) = true;

            if ~isfield(this.datafile, 'channelCompressionHeaders') || isempty(this.datafile.channelCompressionHeaders)
                error('bioread:missingCompressionHeaders', 'Compressed file does not have channel compression headers.');
            end

            if exist('zlibdecode', 'file') ~= 2
                error('bioread:missingZlibdecode', 'MATLAB function zlibdecode is required to read compressed ACQ files.');
            end

            for channelIndex = 1:channelCount
                if ~selectedMask(channelIndex)
                    channels(channelIndex).rawData = [];
                    channels(channelIndex).data = [];
                    channels(channelIndex).loaded = false;
                    continue;
                end

                compressionHeader = this.datafile.channelCompressionHeaders(channelIndex);
                fseek(this.acqFileId, compressionHeader.compressedDataOffset, 'bof');
                compressedData = fread(this.acqFileId, compressionHeader.compressedDataLen, 'uint8=>uint8');

                if isempty(compressedData)
                    channels(channelIndex).rawData = [];
                    channels(channelIndex).data = [];
                    channels(channelIndex).loaded = false;
                    continue;
                end

                decompressedData = zlibdecode(uint8(compressedData));
                rawData = bioread.DataReader.bytesToTypedData( ...
                    decompressedData, ...
                    channels(channelIndex).dtypeCode, ...
                    '<', ...
                    channels(channelIndex).pointCount ...
                );

                channels(channelIndex).rawData = rawData;
                channels(channelIndex).data = bioread.DataReader.scaleChannelData(channels(channelIndex));
                channels(channelIndex).loaded = true;
            end

            this.datafile.channels = channels;
            datafile = bioread.Reader.refreshDatafileCaches(this.datafile);
        end

        function datafile = readDataUncompressed(this, channelIndexes, targetChunkSize)
            channels = this.datafile.channels;
            channelCount = numel(channels);
            selectedIndexes = bioread.DataReader.normalizeChannelIndexes(channelIndexes, channelCount);
            selectedMask = false(1, channelCount);
            selectedMask(selectedIndexes) = true;

            fseek(this.acqFileId, this.dataStartOffset, 'bof');

            channelBytesRemaining = double([channels.dataLength]);
            byteWriteOffsets = zeros(1, channelCount);
            channelByteBuffers = cell(1, channelCount);

            for channelIndex = selectedIndexes
                channelByteBuffers{channelIndex} = zeros(1, channels(channelIndex).dataLength, 'uint8');
            end

            bytePattern = bioread.DataReader.chunkBytePattern(channels, targetChunkSize);

            while sum(channelBytesRemaining) > 0
                patternForChunk = bioread.DataReader.chunkPattern(bytePattern, channelBytesRemaining);
                chunkBytes = numel(patternForChunk);
                if chunkBytes <= 0
                    break;
                end

                chunkData = fread(this.acqFileId, chunkBytes, 'uint8=>uint8')';
                if isempty(chunkData)
                    break;
                end

                trimmedPattern = patternForChunk(1:numel(chunkData));

                for channelIndex = selectedIndexes
                    channelChunkBytes = chunkData(trimmedPattern == channelIndex);
                    if isempty(channelChunkBytes)
                        continue;
                    end

                    writeStart = byteWriteOffsets(channelIndex) + 1;
                    writeStop = min(writeStart + numel(channelChunkBytes) - 1, numel(channelByteBuffers{channelIndex}));
                    bytesToWrite = writeStop - writeStart + 1;
                    if bytesToWrite > 0
                        channelByteBuffers{channelIndex}(writeStart:writeStop) = channelChunkBytes(1:bytesToWrite);
                        byteWriteOffsets(channelIndex) = writeStop;
                    end
                end

                patternCounts = accumarray(double(trimmedPattern(:)), 1, [channelCount, 1])';
                channelBytesRemaining = max(0, channelBytesRemaining - patternCounts);

                if numel(chunkData) < chunkBytes
                    break;
                end
            end

            for channelIndex = 1:channelCount
                if ~selectedMask(channelIndex)
                    channels(channelIndex).rawData = [];
                    channels(channelIndex).data = [];
                    channels(channelIndex).loaded = false;
                    continue;
                end

                rawByteBuffer = channelByteBuffers{channelIndex};
                rawData = bioread.DataReader.bytesToTypedData( ...
                    rawByteBuffer, ...
                    channels(channelIndex).dtypeCode, ...
                    this.byteOrderChar, ...
                    channels(channelIndex).pointCount ...
                );

                channels(channelIndex).rawData = rawData;
                channels(channelIndex).data = bioread.DataReader.scaleChannelData(channels(channelIndex));
                channels(channelIndex).loaded = true;
            end

            this.datafile.channels = channels;
            datafile = bioread.Reader.refreshDatafileCaches(this.datafile);
        end
    end

    methods (Static, Access = private)
        function selectedIndexes = normalizeChannelIndexes(channelIndexes, channelCount)
            if isempty(channelIndexes)
                selectedIndexes = 1:channelCount;
                return;
            end

            selectedIndexes = unique(channelIndexes(:).');
            if any(mod(selectedIndexes, 1) ~= 0)
                error('bioread:invalidChannelIndexes', 'channelIndexes must be integers.');
            end
            if any(selectedIndexes < 1) || any(selectedIndexes > channelCount)
                error('bioread:invalidChannelIndexes', 'channelIndexes are out of range.');
            end
        end

        function scaledData = scaleChannelData(channel)
            if isempty(channel.rawData)
                scaledData = [];
                return;
            end

            if strcmp(channel.dtypeCode, 'f8')
                scaledData = double(channel.rawData);
            else
                scaledData = (double(channel.rawData) * channel.rawScaleFactor) + channel.rawOffset;
            end
        end

        function typedData = bytesToTypedData(rawBytes, dtypeCode, byteOrderChar, pointCount)
            rawBytes = uint8(rawBytes(:).');
            switch dtypeCode
                case 'i2'
                    elementByteCount = 2;
                    readLength = floor(numel(rawBytes) / elementByteCount) * elementByteCount;
                    typedData = typecast(rawBytes(1:readLength), 'int16');
                case 'f8'
                    elementByteCount = 8;
                    readLength = floor(numel(rawBytes) / elementByteCount) * elementByteCount;
                    typedData = typecast(rawBytes(1:readLength), 'double');
                otherwise
                    error('bioread:unsupportedDtype', 'Unsupported channel dtype code: %s', dtypeCode);
            end

            if ~bioread.DataReader.byteOrderMatchesNative(byteOrderChar)
                typedData = swapbytes(typedData);
            end

            if nargin >= 4 && ~isempty(pointCount) && numel(typedData) > pointCount
                typedData = typedData(1:pointCount);
            end
        end

        function matches = byteOrderMatchesNative(byteOrderChar)
            [~, ~, endianCode] = computer;
            if byteOrderChar == '<'
                matches = strcmpi(endianCode, 'L');
            else
                matches = strcmpi(endianCode, 'B');
            end
        end

        function bytePattern = chunkBytePattern(channels, targetChunkSize)
            frequencyDividers = [channels.frequencyDivider];
            sampleSizes = [channels.sampleSize];

            samplePattern = bioread.DataReader.samplePattern(frequencyDividers);
            byteCounts = sampleSizes(samplePattern);
            basePattern = repelem(samplePattern, byteCounts);

            repetitions = bioread.DataReader.chunkPatternReps(targetChunkSize, numel(basePattern));
            bytePattern = repmat(basePattern, 1, repetitions);
        end

        function pattern = samplePattern(frequencyDividers)
            dividers = double(frequencyDividers(:).');
            channelCount = numel(dividers);
            baseLength = bioread.DataReader.leastCommonMultiple(dividers);

            patternSlots = repmat((0:(baseLength - 1)).', 1, channelCount);
            dividerMatrix = repmat(dividers, baseLength, 1);
            patternMask = mod(patternSlots, dividerMatrix) == 0;
            channelSlots = repmat(1:channelCount, baseLength, 1);
            % Python flattens boolean-indexed arrays in row-major order.
            % MATLAB uses column-major order, so transpose first to match.
            transposedSlots = channelSlots.';
            transposedMask = patternMask.';
            pattern = transposedSlots(transposedMask).';
        end

        function repetitions = chunkPatternReps(targetChunkSize, patternByteLength)
            if patternByteLength <= 0
                repetitions = 1;
            else
                repetitions = max(1, floor(targetChunkSize / patternByteLength));
            end
        end

        function pattern = chunkPattern(bytePattern, channelBytesRemaining)
            channelCount = numel(channelBytesRemaining);
            basePatternCounts = accumarray(double(bytePattern(:)), 1, [channelCount, 1])';
            if all(basePatternCounts <= channelBytesRemaining)
                pattern = bytePattern;
                return;
            end

            selectedIndexes = [];
            for channelIndex = 1:channelCount
                channelPositions = find(bytePattern == channelIndex);
                keepCount = min(numel(channelPositions), channelBytesRemaining(channelIndex));
                if keepCount > 0
                    selectedIndexes = [selectedIndexes, channelPositions(1:keepCount)]; %#ok<AGROW>
                end
            end

            selectedIndexes = sort(selectedIndexes);
            pattern = bytePattern(selectedIndexes);
        end

        function lcmValue = leastCommonMultiple(values)
            values = double(values(:).');
            if isempty(values)
                lcmValue = 1;
                return;
            end

            lcmValue = values(1);
            for valueIndex = 2:numel(values)
                lcmValue = bioread.DataReader.pairwiseLcm(lcmValue, values(valueIndex));
            end
        end

        function lcmValue = pairwiseLcm(a, b)
            if a == 0 || b == 0
                lcmValue = 0;
                return;
            end
            lcmValue = abs((a * b) / bioread.DataReader.greatestCommonDenominator(a, b));
        end

        function gcdValue = greatestCommonDenominator(a, b)
            a = abs(a);
            b = abs(b);
            while b ~= 0
                remainder = mod(a, b);
                a = b;
                b = remainder;
            end
            gcdValue = a;
        end
    end
end
