function datafile = read(filelike, channelIndexes, targetChunkSize)
%READ Read a BIOPAC ACQ file and return a MATLAB datafile struct.

    if nargin < 2
        channelIndexes = [];
    end
    if nargin < 3
        targetChunkSize = bioread.DataReader.chunkSize();
    end

    readerObject = bioread.Reader.read(filelike, channelIndexes, targetChunkSize);
    datafile = readerObject.datafile;
end
