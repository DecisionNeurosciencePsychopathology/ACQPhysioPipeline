%READER ACQ file parser used by matlabBioread.
% This class is a MATLAB adaptation of the Python bioread reader flow:
% https://github.com/njvack/bioread
% See matlabBioread/COPYRIGHT and matlabBioread/LICENSE for attribution
% and license terms preserved with this adaptation.
classdef Reader < handle
    properties
        acqFileId (1, 1) double
        filePath (1, :) char
        encoding (1, :) char = 'utf-8'
        datafile struct = struct()
        byteOrderChar (1, 1) char = '<'
        machineFormat (1, :) char = 'ieee-le'
        fileRevision (1, 1) double = NaN
        versionString (1, :) char = ''
        samplesPerSecond (1, 1) double = NaN
        headers cell = {}
        graphHeader struct = struct()
        channelHeaders struct = struct([])
        channelDtypeHeaders struct = struct([])
        channelCompressionHeaders struct = struct([])
        dataStartOffset (1, 1) double = NaN
        dataLength (1, 1) double = NaN
        eventMarkers struct = struct([])
        journal (1, :) char = ''
        readErrors cell = {}
    end

    methods (Static)
        function readerObject = read(fileLike, channelIndexes, targetChunkSize)
            if nargin < 2
                channelIndexes = [];
            end
            if nargin < 3 || isempty(targetChunkSize)
                targetChunkSize = bioread.DataReader.chunkSize();
            end

            filePath = bioread.Reader.normalizeFilePath(fileLike);
            [acqFileId, openMessage] = fopen(filePath, 'rb');
            if acqFileId < 0
                error('bioread:openFailed', 'Could not open "%s": %s', filePath, openMessage);
            end
            fileCloser = onCleanup(@() fclose(acqFileId)); %#ok<NASGU>

            readerObject = bioread.Reader(acqFileId, filePath);

            try
                readerObject.readHeadersInternal();
            catch readException
                readerObject.readErrors{end + 1} = readException.message;
                rethrow(readException);
            end

            try
                readerObject.readDataInternal(channelIndexes, targetChunkSize);
            catch readException
                readerObject.readErrors{end + 1} = readException.message;
                rethrow(readException);
            end
        end

        function readerObject = readHeaders(fileLike)
            filePath = bioread.Reader.normalizeFilePath(fileLike);
            [acqFileId, openMessage] = fopen(filePath, 'rb');
            if acqFileId < 0
                error('bioread:openFailed', 'Could not open "%s": %s', filePath, openMessage);
            end
            fileCloser = onCleanup(@() fclose(acqFileId)); %#ok<NASGU>

            readerObject = bioread.Reader(acqFileId, filePath);
            try
                readerObject.readHeadersInternal();
            catch readException
                readerObject.readErrors{end + 1} = readException.message;
                rethrow(readException);
            end
        end

        function datafile = refreshDatafileCaches(datafile)
            if ~isfield(datafile, 'channels') || isempty(datafile.channels)
                datafile.channelOrderMap = containers.Map('KeyType', 'double', 'ValueType', 'any');
                datafile.namedChannels = containers.Map('KeyType', 'char', 'ValueType', 'any');
                if ~isfield(datafile, 'eventMarkers')
                    datafile.eventMarkers = bioread.Reader.emptyMarkerArray();
                end
                datafile.earliestMarkerCreatedAt = NaT;
                return;
            end

            datafile.channelOrderMap = bioread.Reader.buildChannelOrderMap(datafile.channels);
            datafile.namedChannels = bioread.Reader.buildNamedChannels(datafile.channels);

            if ~isfield(datafile, 'eventMarkers') || isempty(datafile.eventMarkers)
                datafile.eventMarkers = bioread.Reader.emptyMarkerArray();
            end

            datafile = bioread.Reader.attachMarkerChannels(datafile);
            datafile.earliestMarkerCreatedAt = bioread.Reader.computeEarliestMarkerCreatedAt(datafile.eventMarkers);
        end
    end

    methods
        function this = Reader(acqFileId, filePath)
            this.acqFileId = acqFileId;
            this.filePath = char(filePath);
        end

        function readHeadersInternal(this)
            [fileRevision, byteOrderChar, machineFormat, encoding] = ...
                bioread.Reader.bootstrapOrderAndRevision(this.acqFileId);

            if fileRevision < bioread.Reader.v400b()
                error( ...
                    'bioread:unsupportedRevision', ...
                    ['File revision %d is not yet supported by the MATLAB-only reader. ' ...
                     'Supported revisions are >= %d (AcqKnowledge 4+).'], ...
                    fileRevision, bioread.Reader.v400b() ...
                );
            end

            this.fileRevision = fileRevision;
            this.byteOrderChar = byteOrderChar;
            this.machineFormat = machineFormat;
            this.encoding = encoding;
            this.versionString = bioread.Reader.versionStringGuess(this.fileRevision);

            this.graphHeader = bioread.Reader.readGraphHeader( ...
                this.acqFileId, ...
                this.fileRevision, ...
                this.machineFormat, ...
                this.byteOrderChar, ...
                this.encoding ...
            );
            this.headers{end + 1} = this.graphHeader;

            channelCount = this.graphHeader.channelCount;
            if channelCount <= 0
                error('bioread:invalidChannelCount', 'Invalid channel count (%d).', channelCount);
            end

            padOffset = this.graphHeader.effectiveLenBytes;
            [paddingHeaders, channelOffset] = bioread.Reader.readPaddingHeaders( ...
                this.acqFileId, ...
                padOffset, ...
                this.graphHeader.expectedPaddingHeaders, ...
                this.machineFormat ...
            );
            if ~isempty(paddingHeaders)
                this.headers = [this.headers, num2cell(paddingHeaders)]; %#ok<AGROW>
            end

            [this.channelHeaders, foreignOffset] = bioread.Reader.readChannelHeaders( ...
                this.acqFileId, ...
                channelOffset, ...
                channelCount, ...
                this.machineFormat, ...
                this.encoding, ...
                this.fileRevision ...
            );
            this.headers = [this.headers, num2cell(this.channelHeaders)]; %#ok<AGROW>

            foreignHeader = bioread.Reader.readForeignHeader( ...
                this.acqFileId, ...
                foreignOffset, ...
                this.machineFormat, ...
                this.fileRevision ...
            );
            this.headers{end + 1} = foreignHeader;

            dtypeOffset = foreignOffset + foreignHeader.effectiveLenBytes;
            [this.channelDtypeHeaders, this.dataStartOffset] = bioread.Reader.scanForDtypeHeaders( ...
                this.acqFileId, ...
                dtypeOffset, ...
                channelCount, ...
                this.machineFormat, ...
                this.byteOrderChar, ...
                this.graphHeader.compressed ...
            );
            this.headers = [this.headers, num2cell(this.channelDtypeHeaders)]; %#ok<AGROW>

            this.samplesPerSecond = 1000 / this.graphHeader.sampleTime;

            this.datafile = bioread.Reader.createDatafileStruct( ...
                this.graphHeader, ...
                this.channelHeaders, ...
                this.channelDtypeHeaders, ...
                this.samplesPerSecond, ...
                this.filePath, ...
                this.versionString ...
            );

            this.dataLength = bioread.Reader.calculateDataLength( ...
                this.channelHeaders, ...
                this.channelDtypeHeaders, ...
                this.graphHeader.compressed ...
            );

            markerStartOffset = this.dataStartOffset + this.dataLength;
            [this.eventMarkers, journalOffset] = bioread.Reader.readMarkers( ...
                this.acqFileId, ...
                markerStartOffset, ...
                this.machineFormat, ...
                this.fileRevision, ...
                this.encoding, ...
                this.graphHeader.sampleTime ...
            );
            this.datafile.eventMarkers = this.eventMarkers;
            this.datafile = bioread.Reader.attachMarkerChannels(this.datafile);
            this.datafile.earliestMarkerCreatedAt = bioread.Reader.computeEarliestMarkerCreatedAt(this.datafile.eventMarkers);

            [this.journal, compressionOffset] = bioread.Reader.readJournal( ...
                this.acqFileId, ...
                journalOffset, ...
                this.fileRevision, ...
                this.machineFormat, ...
                this.encoding ...
            );
            this.datafile.journal = this.journal;

            if this.graphHeader.compressed
                this.channelCompressionHeaders = bioread.Reader.readCompressionHeaders( ...
                    this.acqFileId, ...
                    compressionOffset, ...
                    this.machineFormat, ...
                    this.fileRevision, ...
                    channelCount ...
                );
            else
                this.channelCompressionHeaders = struct([]);
            end
            this.datafile.channelCompressionHeaders = this.channelCompressionHeaders;

            this.datafile = bioread.Reader.refreshDatafileCaches(this.datafile);
        end

        function readDataInternal(this, channelIndexes, targetChunkSize)
            dataReader = bioread.DataReader( ...
                this.acqFileId, ...
                this.datafile, ...
                this.dataStartOffset, ...
                this.fileRevision, ...
                this.byteOrderChar ...
            );
            this.datafile = dataReader.readData(channelIndexes, targetChunkSize);
        end
    end

    methods (Static, Access = private)
        function filePath = normalizeFilePath(fileLike)
            if isstring(fileLike)
                if ~isscalar(fileLike)
                    error('bioread:invalidPath', 'filePath must be a scalar string or char array.');
                end
                filePath = char(fileLike);
            elseif ischar(fileLike)
                filePath = fileLike;
            else
                error('bioread:invalidPath', 'filePath must be a string or char array.');
            end

            if strlength(string(filePath)) == 0
                error('bioread:invalidPath', 'filePath must not be empty.');
            end
        end

        function [fileRevision, byteOrderChar, machineFormat, encoding] = bootstrapOrderAndRevision(acqFileId)
            fseek(acqFileId, 2, 'bof');
            revisionLittle = bioread.Reader.mustRead(acqFileId, 1, 'uint32', 'ieee-le', 'graphHeader.lVersion(little-endian)');
            fseek(acqFileId, 2, 'bof');
            revisionBig = bioread.Reader.mustRead(acqFileId, 1, 'uint32', 'ieee-be', 'graphHeader.lVersion(big-endian)');

            revisionCandidates = [double(revisionLittle), double(revisionBig)];
            [fileRevision, selectedIndex] = min(revisionCandidates);

            if selectedIndex == 1
                byteOrderChar = '<';
                machineFormat = 'ieee-le';
            else
                byteOrderChar = '>';
                machineFormat = 'ieee-be';
            end

            if fileRevision < bioread.Reader.v400b()
                encoding = 'latin1';
            else
                encoding = 'utf-8';
            end
        end

        function graphHeader = readGraphHeader(acqFileId, fileRevision, machineFormat, byteOrderChar, encoding)
            fseek(acqFileId, 0, 'bof');
            nItemHeaderLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'graphHeader.nItemHeaderLen')); %#ok<NASGU>
            lVersion = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'graphHeader.lVersion'));
            lExtItemHeaderLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'graphHeader.lExtItemHeaderLen'));
            nChannels = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'graphHeader.nChannels'));

            bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'graphHeader.nHorizAxisType');
            bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'graphHeader.nCurChannel');
            dSampleTime = double(bioread.Reader.mustRead(acqFileId, 1, 'double', machineFormat, 'graphHeader.dSampleTime'));

            fseek(acqFileId, 972, 'bof');
            bCompressed = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'graphHeader.bCompressed'));

            expectedPaddingHeaders = 0;
            if fileRevision >= bioread.Reader.v430()
                fseek(acqFileId, 2398, 'bof');
                expectedPaddingHeaders = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'graphHeader.hExpectedPaddings'));
            end

            graphHeader = struct( ...
                'offset', 0, ...
                'fileRevision', fileRevision, ...
                'versionField', lVersion, ...
                'byteOrderChar', byteOrderChar, ...
                'encoding', encoding, ...
                'effectiveLenBytes', lExtItemHeaderLen, ...
                'channelCount', nChannels, ...
                'sampleTime', dSampleTime, ...
                'compressed', logical(bCompressed ~= 0), ...
                'expectedPaddingHeaders', max(0, expectedPaddingHeaders) ...
            );
        end

        function [paddingHeaders, nextOffset] = readPaddingHeaders(acqFileId, startOffset, paddingCount, machineFormat)
            paddingTemplate = struct( ...
                'offset', 0, ...
                'effectiveLenBytes', 0 ...
            );

            if paddingCount <= 0
                paddingHeaders = paddingTemplate([]);
                nextOffset = startOffset;
                return;
            end

            paddingHeaders = repmat(paddingTemplate, 1, paddingCount);
            currentOffset = startOffset;
            for padIndex = 1:paddingCount
                fseek(acqFileId, currentOffset, 'bof');
                channelLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'unknownPadding.lChannelLen'));
                if channelLen <= 0
                    error('bioread:invalidPaddingHeader', 'Invalid padding length (%d) at offset %d.', channelLen, currentOffset);
                end
                paddingHeaders(padIndex) = struct( ...
                    'offset', currentOffset, ...
                    'effectiveLenBytes', channelLen ...
                );
                currentOffset = currentOffset + channelLen;
            end

            nextOffset = currentOffset;
        end

        function [channelHeaders, nextOffset] = readChannelHeaders(acqFileId, startOffset, channelCount, machineFormat, encoding, fileRevision)
            channelTemplate = struct( ...
                'offset', 0, ...
                'effectiveLenBytes', 0, ...
                'channelNumber', 0, ...
                'name', '', ...
                'units', '', ...
                'pointCount', 0, ...
                'rawScale', 0, ...
                'rawOffset', 0, ...
                'orderNum', 0, ...
                'frequencyDivider', 1 ...
            );

            channelHeaders = repmat(channelTemplate, 1, channelCount);
            currentOffset = startOffset;

            for channelIndex = 1:channelCount
                fseek(acqFileId, currentOffset, 'bof');

                channelHeaderLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'channelHeader.lChanHeaderLen'));
                channelNumber = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'channelHeader.nNum'));
                commentBytes = bioread.Reader.mustRead(acqFileId, 40, 'uint8', machineFormat, 'channelHeader.szCommentText');
                bioread.Reader.mustRead(acqFileId, 4, 'uint8', machineFormat, 'channelHeader.color');
                bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'channelHeader.nDispChan');
                bioread.Reader.mustRead(acqFileId, 1, 'double', machineFormat, 'channelHeader.dVoltOffset');
                bioread.Reader.mustRead(acqFileId, 1, 'double', machineFormat, 'channelHeader.dVoltScale');
                unitsBytes = bioread.Reader.mustRead(acqFileId, 20, 'uint8', machineFormat, 'channelHeader.szUnitsText');
                pointCount = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'channelHeader.lBufLength'));
                rawScale = double(bioread.Reader.mustRead(acqFileId, 1, 'double', machineFormat, 'channelHeader.dAmplScale'));
                rawOffset = double(bioread.Reader.mustRead(acqFileId, 1, 'double', machineFormat, 'channelHeader.dAmplOffset'));
                orderNum = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'channelHeader.nChanOrder'));
                bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'channelHeader.nDispSize');

                frequencyDivider = 1;
                if fileRevision >= bioread.Reader.v400b()
                    bioread.Reader.mustRead(acqFileId, 40, 'uint8', machineFormat, 'channelHeader.unknown');
                    frequencyDivider = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'channelHeader.nVarSampleDivider'));
                end
                if frequencyDivider == 0
                    frequencyDivider = 1;
                end

                if channelHeaderLen <= 0
                    error('bioread:invalidChannelHeader', 'Invalid channel header length (%d) at offset %d.', channelHeaderLen, currentOffset);
                end

                channelHeaders(channelIndex) = struct( ...
                    'offset', currentOffset, ...
                    'effectiveLenBytes', channelHeaderLen, ...
                    'channelNumber', channelNumber, ...
                    'name', bioread.Reader.decodeFixedString(commentBytes, encoding), ...
                    'units', bioread.Reader.decodeFixedString(unitsBytes, encoding), ...
                    'pointCount', pointCount, ...
                    'rawScale', rawScale, ...
                    'rawOffset', rawOffset, ...
                    'orderNum', orderNum, ...
                    'frequencyDivider', max(1, frequencyDivider) ...
                );

                currentOffset = currentOffset + channelHeaderLen;
            end

            nextOffset = currentOffset;
        end

        function foreignHeader = readForeignHeader(acqFileId, offset, machineFormat, fileRevision)
            fseek(acqFileId, offset, 'bof');
            if fileRevision >= bioread.Reader.v400b()
                foreignLength = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'foreignHeader.lLength'));
            else
                foreignLength = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'foreignHeader.nLength'));
            end

            if foreignLength < 0
                error('bioread:invalidForeignHeader', 'Invalid foreign header length (%d) at offset %d.', foreignLength, offset);
            end

            foreignHeader = struct( ...
                'offset', offset, ...
                'effectiveLenBytes', foreignLength ...
            );
        end

        function [dtypeHeaders, dataStartOffset] = scanForDtypeHeaders(acqFileId, startOffset, channelCount, machineFormat, byteOrderChar, isCompressed)
            scanTemplate = struct( ...
                'offset', 0, ...
                'sampleSize', 0, ...
                'typeCode', 0, ...
                'dtypeCode', '', ...
                'dtypeString', '', ...
                'possiblyValid', false ...
            );

            for scanIndex = 0:(bioread.Reader.maxDtypeScans() - 1)
                candidateOffset = startOffset + scanIndex;
                try
                    [candidateHeaders, allValid] = bioread.Reader.readDtypeHeadersAtOffset( ...
                        acqFileId, ...
                        candidateOffset, ...
                        channelCount, ...
                        machineFormat, ...
                        byteOrderChar, ...
                        isCompressed ...
                    );
                catch
                    candidateHeaders = scanTemplate([]);
                    allValid = false;
                end

                if allValid
                    dtypeHeaders = candidateHeaders;
                    dataStartOffset = candidateOffset + (4 * channelCount);
                    return;
                end
            end

            error('bioread:dtypeNotFound', 'Could not find valid channel dtype headers after scanning %d bytes.', bioread.Reader.maxDtypeScans());
        end

        function [dtypeHeaders, allValid] = readDtypeHeadersAtOffset(acqFileId, offset, channelCount, machineFormat, byteOrderChar, isCompressed)
            dtypeTemplate = struct( ...
                'offset', 0, ...
                'sampleSize', 0, ...
                'typeCode', 0, ...
                'dtypeCode', '', ...
                'dtypeString', '', ...
                'possiblyValid', false ...
            );

            dtypeHeaders = repmat(dtypeTemplate, 1, channelCount);
            fseek(acqFileId, offset, 'bof');
            allValid = true;

            dataByteOrder = byteOrderChar;
            if isCompressed
                dataByteOrder = '<';
            end

            for channelIndex = 1:channelCount
                sampleSize = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'dtypeHeader.nSize'));
                typeCode = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'dtypeHeader.nType'));
                [dtypeCode, expectedSize] = bioread.Reader.mapDtypeCode(typeCode);

                isPossiblyValid = ~isempty(dtypeCode) && expectedSize == sampleSize;
                dtypeHeaders(channelIndex) = struct( ...
                    'offset', offset + ((channelIndex - 1) * 4), ...
                    'sampleSize', sampleSize, ...
                    'typeCode', typeCode, ...
                    'dtypeCode', dtypeCode, ...
                    'dtypeString', [dataByteOrder, dtypeCode], ...
                    'possiblyValid', isPossiblyValid ...
                );

                if ~isPossiblyValid
                    allValid = false;
                end
            end
        end

        function [dtypeCode, expectedSize] = mapDtypeCode(typeCode)
            switch typeCode
                case {0, 1}
                    dtypeCode = 'f8';
                    expectedSize = 8;
                case 2
                    dtypeCode = 'i2';
                    expectedSize = 2;
                otherwise
                    dtypeCode = '';
                    expectedSize = NaN;
            end
        end

        function datafile = createDatafileStruct(graphHeader, channelHeaders, channelDtypeHeaders, samplesPerSecond, filePath, versionString)
            channels = bioread.Reader.buildChannels(channelHeaders, channelDtypeHeaders, samplesPerSecond);
            datafile = struct( ...
                'graphHeader', graphHeader, ...
                'channelHeaders', channelHeaders, ...
                'channelDtypeHeaders', channelDtypeHeaders, ...
                'samplesPerSecond', samplesPerSecond, ...
                'name', filePath, ...
                'versionString', versionString, ...
                'eventMarkers', bioread.Reader.emptyMarkerArray(), ...
                'journal', '', ...
                'channels', channels, ...
                'channelOrderMap', bioread.Reader.buildChannelOrderMap(channels), ...
                'namedChannels', bioread.Reader.buildNamedChannels(channels), ...
                'channelCompressionHeaders', struct([]), ...
                'isCompressed', graphHeader.compressed, ...
                'timeIndex', [], ...
                'earliestMarkerCreatedAt', NaT ...
            );
        end

        function channels = buildChannels(channelHeaders, channelDtypeHeaders, samplesPerSecond)
            channelTemplate = struct( ...
                'index', 0, ...
                'frequencyDivider', 1, ...
                'rawScaleFactor', 1, ...
                'rawOffset', 0, ...
                'name', '', ...
                'units', '', ...
                'fmtStr', '', ...
                'dtypeCode', '', ...
                'samplesPerSecond', NaN, ...
                'pointCount', 0, ...
                'orderNum', 0, ...
                'sampleSize', 0, ...
                'dataLength', 0, ...
                'rawData', [], ...
                'data', [], ...
                'upsampledData', [], ...
                'timeIndex', [], ...
                'loaded', false ...
            );

            channelCount = numel(channelHeaders);
            channels = repmat(channelTemplate, 1, channelCount);

            for channelIndex = 1:channelCount
                header = channelHeaders(channelIndex);
                dtypeHeader = channelDtypeHeaders(channelIndex);

                frequencyDivider = max(1, double(header.frequencyDivider));
                pointCount = max(0, double(header.pointCount));
                sampleSize = max(0, double(dtypeHeader.sampleSize));
                rawScaleFactor = double(header.rawScale);
                rawOffset = double(header.rawOffset);

                if strcmp(dtypeHeader.dtypeCode, 'f8')
                    rawScaleFactor = 1;
                    rawOffset = 0;
                end

                channels(channelIndex) = struct( ...
                    'index', channelIndex, ...
                    'frequencyDivider', frequencyDivider, ...
                    'rawScaleFactor', rawScaleFactor, ...
                    'rawOffset', rawOffset, ...
                    'name', header.name, ...
                    'units', header.units, ...
                    'fmtStr', dtypeHeader.dtypeString, ...
                    'dtypeCode', dtypeHeader.dtypeCode, ...
                    'samplesPerSecond', samplesPerSecond / frequencyDivider, ...
                    'pointCount', pointCount, ...
                    'orderNum', double(header.orderNum), ...
                    'sampleSize', sampleSize, ...
                    'dataLength', pointCount * sampleSize, ...
                    'rawData', [], ...
                    'data', [], ...
                    'upsampledData', [], ...
                    'timeIndex', [], ...
                    'loaded', false ...
                );
            end
        end

        function channelOrderMap = buildChannelOrderMap(channels)
            channelOrderMap = containers.Map('KeyType', 'double', 'ValueType', 'any');
            for channelIndex = 1:numel(channels)
                orderNumber = channels(channelIndex).orderNum;
                if ~isnan(orderNumber)
                    channelOrderMap(orderNumber) = channels(channelIndex);
                end
            end
        end

        function namedChannels = buildNamedChannels(channels)
            namedChannels = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for channelIndex = 1:numel(channels)
                channelName = channels(channelIndex).name;
                if strlength(string(channelName)) > 0
                    namedChannels(channelName) = channels(channelIndex);
                end
            end
        end

        function dataLength = calculateDataLength(channelHeaders, channelDtypeHeaders, isCompressed)
            if isCompressed
                dataLength = 0;
                return;
            end

            dataLength = 0;
            for channelIndex = 1:numel(channelHeaders)
                dataLength = dataLength + ...
                    (double(channelHeaders(channelIndex).pointCount) * double(channelDtypeHeaders(channelIndex).sampleSize));
            end
        end

        function [eventMarkers, nextOffset] = readMarkers(acqFileId, markerStartOffset, machineFormat, fileRevision, encoding, sampleTime)
            eventMarkers = bioread.Reader.emptyMarkerArray();
            nextOffset = markerStartOffset;

            fileSize = bioread.Reader.getFileSize(acqFileId);
            if markerStartOffset >= fileSize
                return;
            end

            [markerHeader, currentOffset] = bioread.Reader.readMarkerHeader( ...
                acqFileId, ...
                markerStartOffset, ...
                machineFormat, ...
                fileRevision ...
            );

            markerCount = markerHeader.markerCount;
            if markerCount <= 0
                nextOffset = currentOffset;
                return;
            end

            markerTemplate = bioread.Reader.markerTemplate();
            eventMarkers = repmat(markerTemplate, 1, markerCount);

            for markerIndex = 1:markerCount
                [eventMarker, currentOffset] = bioread.Reader.readMarkerItem( ...
                    acqFileId, ...
                    currentOffset, ...
                    machineFormat, ...
                    fileRevision, ...
                    encoding, ...
                    sampleTime ...
                );
                eventMarker.index = markerIndex;
                eventMarkers(markerIndex) = eventMarker;
            end

            nextOffset = currentOffset;
        end

        function [markerHeader, markerItemsOffset] = readMarkerHeader(acqFileId, offset, machineFormat, fileRevision)
            fseek(acqFileId, offset, 'bof');
            lLength = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'markerHeader.lLength')); %#ok<NASGU>
            lMarkersExtra = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'markerHeader.lMarkersExtra'));
            lMarkers = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'markerHeader.lMarkers')); %#ok<NASGU>

            bioread.Reader.mustRead(acqFileId, 6, 'uint8', machineFormat, 'markerHeader.unknown');
            bioread.Reader.mustRead(acqFileId, 5, 'uint8', machineFormat, 'markerHeader.szDefl');
            bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'markerHeader.unknown2');

            headerLength = 25;
            if fileRevision >= bioread.Reader.v42x()
                bioread.Reader.mustRead(acqFileId, 8, 'uint8', machineFormat, 'markerHeader.unknown3');
                headerLength = headerLength + 8;
            end
            if fileRevision >= bioread.Reader.v440()
                bioread.Reader.mustRead(acqFileId, 8, 'uint8', machineFormat, 'markerHeader.unknown4');
                headerLength = headerLength + 8;
            end

            markerCount = max(0, lMarkersExtra - 1);
            markerHeader = struct( ...
                'offset', offset, ...
                'effectiveLenBytes', headerLength, ...
                'markerCount', markerCount ...
            );

            markerItemsOffset = offset + headerLength;
        end

        function [eventMarker, nextOffset] = readMarkerItem(acqFileId, itemOffset, machineFormat, fileRevision, encoding, sampleTime)
            fseek(acqFileId, itemOffset, 'bof');
            sampleIndex = double(bioread.Reader.mustRead(acqFileId, 1, 'uint32', machineFormat, 'markerItem.lSample'));
            bioread.Reader.mustRead(acqFileId, 4, 'uint8', machineFormat, 'markerItem.unknown');
            rawChannelNumber = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'markerItem.nChannel'));
            markerStyleBytes = bioread.Reader.mustRead(acqFileId, 4, 'uint8', machineFormat, 'markerItem.sMarkerStyle');

            headerLength = 16;
            dateCreatedMs = NaN;
            if fileRevision >= bioread.Reader.v440()
                dateCreatedMs = double(bioread.Reader.mustRead(acqFileId, 1, 'uint64', machineFormat, 'markerItem.llDateCreated'));
                headerLength = headerLength + 8;
            end
            if fileRevision >= bioread.Reader.v42x()
                bioread.Reader.mustRead(acqFileId, 8, 'uint8', machineFormat, 'markerItem.unknown3');
                headerLength = headerLength + 8;
            end

            textLength = double(bioread.Reader.mustRead(acqFileId, 1, 'int16', machineFormat, 'markerItem.nTextLength'));
            textLength = max(0, textLength);

            fseek(acqFileId, itemOffset + headerLength, 'bof');
            markerTextBytes = uint8([]);
            if textLength > 0
                markerTextBytes = bioread.Reader.mustRead(acqFileId, textLength, 'uint8', machineFormat, 'markerItem.text');
            end

            markerText = bioread.Reader.decodeFixedString(markerTextBytes, encoding);
            typeCode = bioread.Reader.decodeFixedString(markerStyleBytes, 'latin1');
            if isempty(typeCode)
                typeCode = 'None';
            end

            channelNumber = rawChannelNumber;
            if rawChannelNumber == -1
                channelNumber = NaN;
            end

            dateCreatedUtc = NaT;
            if ~isnan(dateCreatedMs)
                try
                    dateCreatedUtc = datetime(1970, 1, 1, 'TimeZone', 'UTC') + milliseconds(dateCreatedMs);
                catch
                    dateCreatedUtc = NaT;
                end
            end

            eventMarker = bioread.Reader.markerTemplate();
            eventMarker.timeIndex = (sampleIndex * sampleTime) / 1000;
            eventMarker.sampleIndex = sampleIndex;
            eventMarker.text = markerText;
            eventMarker.channelNumber = channelNumber;
            eventMarker.typeCode = typeCode;
            eventMarker.type = typeCode;
            eventMarker.dateCreatedMs = dateCreatedMs;
            eventMarker.dateCreatedUtc = dateCreatedUtc;

            nextOffset = itemOffset + headerLength + textLength;
        end

        function [journal, nextOffset] = readJournal(acqFileId, journalOffset, fileRevision, machineFormat, encoding)
            journal = '';
            nextOffset = journalOffset;

            fileSize = bioread.Reader.getFileSize(acqFileId);
            if journalOffset >= fileSize
                return;
            end

            fseek(acqFileId, journalOffset, 'bof');
            journalDataLen = double(fread(acqFileId, 1, 'int32=>int32', 0, machineFormat));
            if isempty(journalDataLen)
                return;
            end

            if journalDataLen <= 0
                nextOffset = journalOffset + max(0, journalDataLen);
                fseek(acqFileId, nextOffset, 'bof');
                return;
            end

            dataEnd = min(fileSize, journalOffset + journalDataLen);
            expectedHeaderLen = bioread.Reader.expectedJournalHeaderLength(fileRevision);

            if expectedHeaderLen <= journalDataLen
                headerOffset = journalOffset + 4;
                fseek(acqFileId, headerOffset, 'bof');

                bioread.Reader.mustRead(acqFileId, 262, 'uint8', machineFormat, 'journalHeader.bUnknown1');
                earlyJournalLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'journalHeader.lEarlyJournalLen'));
                bioread.Reader.mustRead(acqFileId, 290, 'uint8', machineFormat, 'journalHeader.bUnknown2');

                journalLen = earlyJournalLen;
                if fileRevision >= bioread.Reader.v420()
                    bioread.Reader.mustRead(acqFileId, 26, 'uint8', machineFormat, 'journalHeader.bUnknown3');
                    if fileRevision >= bioread.Reader.v440()
                        bioread.Reader.mustRead(acqFileId, 4, 'uint8', machineFormat, 'journalHeader.bUnknown4');
                    end
                    bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'journalHeader.lLateJournalLenMinusOne');
                    journalLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'journalHeader.lLateJournalLen'));
                end

                journalLen = max(0, journalLen);
                journalDataOffset = headerOffset + expectedHeaderLen;
                if journalDataOffset < dataEnd
                    readableLen = min(journalLen, dataEnd - journalDataOffset);
                    fseek(acqFileId, journalDataOffset, 'bof');
                    journalBytes = fread(acqFileId, readableLen, 'uint8=>uint8')';
                    journal = bioread.Reader.decodeFixedString(journalBytes, encoding);
                end
            end

            fseek(acqFileId, dataEnd, 'bof');
            nextOffset = dataEnd;
        end

        function expectedLen = expectedJournalHeaderLength(fileRevision)
            if fileRevision < bioread.Reader.v420()
                expectedLen = 556;
            elseif fileRevision < bioread.Reader.v440()
                expectedLen = 590;
            else
                expectedLen = 594;
            end
        end

        function channelCompressionHeaders = readCompressionHeaders(acqFileId, startOffset, machineFormat, fileRevision, channelCount)
            compressionTemplate = struct( ...
                'offset', 0, ...
                'headerOnlyLen', 0, ...
                'effectiveLenBytes', 0, ...
                'compressedDataOffset', 0, ...
                'compressedDataLen', 0, ...
                'uncompressedDataLen', 0 ...
            );

            if channelCount <= 0
                channelCompressionHeaders = compressionTemplate([]);
                return;
            end

            fseek(acqFileId, startOffset, 'bof');
            bioread.Reader.mustRead(acqFileId, 24, 'uint8', machineFormat, 'mainCompressionHeader.unknown1');
            stringLenOne = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'mainCompressionHeader.lStrLen1'));
            stringLenTwo = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'mainCompressionHeader.lStrLen2'));
            bioread.Reader.mustRead(acqFileId, 20, 'uint8', machineFormat, 'mainCompressionHeader.unknown2');

            mainHeaderLen = 52;
            if fileRevision >= bioread.Reader.v420()
                bioread.Reader.mustRead(acqFileId, 6, 'uint8', machineFormat, 'mainCompressionHeader.unknown3');
                mainHeaderLen = 58;
            end

            currentOffset = startOffset + mainHeaderLen + stringLenOne + stringLenTwo;
            channelCompressionHeaders = repmat(compressionTemplate, 1, channelCount);

            for channelIndex = 1:channelCount
                fseek(acqFileId, currentOffset, 'bof');
                bioread.Reader.mustRead(acqFileId, 44, 'uint8', machineFormat, 'channelCompressionHeader.unknown');
                channelLabelLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'channelCompressionHeader.lChannelLabelLen'));
                unitLabelLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'channelCompressionHeader.lUnitLabelLen'));
                uncompressedLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'channelCompressionHeader.lUncompressedLen'));
                compressedLen = double(bioread.Reader.mustRead(acqFileId, 1, 'int32', machineFormat, 'channelCompressionHeader.lCompressedLen'));

                headerOnlyLen = 60 + channelLabelLen + unitLabelLen;
                effectiveLenBytes = headerOnlyLen + compressedLen;

                channelCompressionHeaders(channelIndex) = struct( ...
                    'offset', currentOffset, ...
                    'headerOnlyLen', headerOnlyLen, ...
                    'effectiveLenBytes', effectiveLenBytes, ...
                    'compressedDataOffset', currentOffset + headerOnlyLen, ...
                    'compressedDataLen', compressedLen, ...
                    'uncompressedDataLen', uncompressedLen ...
                );

                currentOffset = currentOffset + effectiveLenBytes;
            end
        end

        function decodedString = decodeFixedString(rawBytes, encoding)
            if isempty(rawBytes)
                decodedString = '';
                return;
            end

            rawBytes = uint8(rawBytes(:).');
            if strcmpi(encoding, 'latin1')
                decodeEncoding = 'ISO-8859-1';
            else
                decodeEncoding = 'UTF-8';
            end

            try
                decodedString = native2unicode(rawBytes, decodeEncoding);
            catch
                decodedString = char(rawBytes);
            end

            decodedString = bioread.Reader.trimNullTerminators(decodedString);
        end

        function trimmed = trimNullTerminators(inputString)
            if isempty(inputString)
                trimmed = '';
                return;
            end

            lastNonNullIndex = find(inputString ~= char(0), 1, 'last');
            if isempty(lastNonNullIndex)
                trimmed = '';
            else
                trimmed = inputString(1:lastNonNullIndex);
            end
        end

        function values = mustRead(acqFileId, count, precision, machineFormat, fieldName)
            readPrecision = sprintf('%s=>%s', precision, precision);
            values = fread(acqFileId, count, readPrecision, 0, machineFormat);
            if numel(values) < count
                error('bioread:unexpectedEof', 'Unexpected end-of-file while reading %s.', fieldName);
            end
        end

        function fileSize = getFileSize(acqFileId)
            currentOffset = ftell(acqFileId);
            fseek(acqFileId, 0, 'eof');
            fileSize = ftell(acqFileId);
            fseek(acqFileId, currentOffset, 'bof');
        end

        function datafile = attachMarkerChannels(datafile)
            if ~isfield(datafile, 'eventMarkers') || isempty(datafile.eventMarkers)
                return;
            end
            if ~isfield(datafile, 'channels') || isempty(datafile.channels)
                return;
            end

            orderNumbers = [datafile.channels.orderNum];
            eventMarkers = datafile.eventMarkers;
            for markerIndex = 1:numel(eventMarkers)
                markerChannel = eventMarkers(markerIndex).channelNumber;
                if ~isnan(markerChannel)
                    matchingChannelIndex = find(orderNumbers == markerChannel, 1, 'first');
                    if ~isempty(matchingChannelIndex)
                        eventMarkers(markerIndex).channelIndex = matchingChannelIndex;
                        eventMarkers(markerIndex).channelName = datafile.channels(matchingChannelIndex).name;
                        channelDivider = max(1, datafile.channels(matchingChannelIndex).frequencyDivider);
                        eventMarkers(markerIndex).channelSampleIndex = floor(eventMarkers(markerIndex).sampleIndex / channelDivider);
                    else
                        eventMarkers(markerIndex).channelIndex = NaN;
                        eventMarkers(markerIndex).channelName = '';
                        eventMarkers(markerIndex).channelSampleIndex = NaN;
                    end
                else
                    eventMarkers(markerIndex).channelIndex = NaN;
                    eventMarkers(markerIndex).channelName = 'Global';
                    eventMarkers(markerIndex).channelSampleIndex = NaN;
                end
            end

            datafile.eventMarkers = eventMarkers;
        end

        function earliestCreatedAt = computeEarliestMarkerCreatedAt(eventMarkers)
            earliestCreatedAt = NaT;
            if isempty(eventMarkers)
                return;
            end
            if ~isfield(eventMarkers, 'dateCreatedUtc')
                return;
            end

            createdAtValues = [eventMarkers.dateCreatedUtc];
            validMask = ~isnat(createdAtValues);
            if any(validMask)
                earliestCreatedAt = min(createdAtValues(validMask));
            end
        end

        function eventMarkers = emptyMarkerArray()
            template = bioread.Reader.markerTemplate();
            eventMarkers = template([]);
        end

        function marker = markerTemplate()
            marker = struct( ...
                'index', 0, ...
                'timeIndex', NaN, ...
                'sampleIndex', NaN, ...
                'text', '', ...
                'channelNumber', NaN, ...
                'channelName', '', ...
                'channelIndex', NaN, ...
                'channelSampleIndex', NaN, ...
                'dateCreatedMs', NaN, ...
                'dateCreatedUtc', NaT, ...
                'typeCode', 'None', ...
                'type', 'None', ...
                'color', '', ...
                'tag', '' ...
            );
        end

        function versionString = versionStringGuess(revision)
            knownRevisions = [30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 45, 61, 68, 76, 78, 80, 83, 84, 108, 121, 124, 128, 132];
            knownVersions = { ...
                '2.0.a', '2.0.b', '2.0.r', '2.0.7', '3.0.r', '3.0.3', '3.5.x', '3.6.x', ...
                '3.7.0', '3.7.3', '3.8.1', '3.7.x', '3.8.2', '3.8.x', '3.9.0', '4.0.0b', ...
                '4.0.0', '4.0.1', '4.0.2', '4.1.a', '4.1.0', '4.1.1', '4.2.0', '4.2.x', ...
                '4.3.0', '4.4.0', '5.0.1' ...
            };

            bslRevisions = [37, 42, 44];
            if any(revision == bslRevisions)
                programName = 'BSL PRO';
            else
                programName = 'AcqKnowledge';
            end

            matchIndex = find(knownRevisions == revision, 1, 'first');
            if ~isempty(matchIndex)
                versionString = sprintf('%s %s', programName, knownVersions{matchIndex});
                return;
            end

            if revision < knownRevisions(1)
                versionString = sprintf('%s, %s', programName, knownVersions{1});
                return;
            end

            if revision > knownRevisions(end)
                versionString = sprintf('%s, after %s', programName, knownVersions{end});
                return;
            end

            upperIndex = find(revision < knownRevisions, 1, 'first');
            lowerIndex = upperIndex - 1;
            versionString = sprintf( ...
                '%s, between %s and %s', ...
                programName, ...
                knownVersions{lowerIndex}, ...
                knownVersions{upperIndex} ...
            );
        end

        function value = maxDtypeScans()
            value = 4096;
        end

        function value = v400b()
            value = 61;
        end

        function value = v420()
            value = 108;
        end

        function value = v42x()
            value = 121;
        end

        function value = v430()
            value = 124;
        end

        function value = v440()
            value = 128;
        end
    end
end
