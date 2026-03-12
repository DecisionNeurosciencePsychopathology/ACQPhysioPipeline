function datafile = readHeaders(filelike)
%READHEADERS Read only ACQ headers and return a MATLAB datafile struct.

    readerObject = bioread.Reader.readHeaders(filelike);
    datafile = readerObject.datafile;
end
