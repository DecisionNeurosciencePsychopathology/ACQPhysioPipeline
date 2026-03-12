# matlabBioread

Pure MATLAB implementation of the `bioread.read(filePath)` flow.

## Files
- `+bioread/read.m`: MATLAB equivalent of Python `bioread.read(...)`.
- `+bioread/readHeaders.m`: MATLAB equivalent of Python `bioread.read_headers(...)`.
- `+bioread/Reader.m`: MATLAB parser class following Python `reader.Reader` structure.
- `+bioread/DataReader.m`: MATLAB data loading logic following Python `data_reader`.
- `biopacReader.m`: object wrapper that takes a filename and returns parsed data.


## Usage
1. Open MATLAB with this repository as the current folder.
2. Run:

```matlab
addpath('matlabBioread');
data = bioread.read('path/to/file.acq');
```

## Attribution and licensing
- `matlabBioread` adapts the ACQ reading flow from the upstream Python project [`bioread`](https://github.com/njvack/bioread).
- Upstream copyright notice:

```
Copyright (c) 2025 Board of Regents of the University of Wisconsin System

Written Nate Vack <njvack@wisc.edu> with research from John Ollinger
at the Waisman Laboratory for Brain Imaging and Behavior, University of
Wisconsin-Madison
Project home: http://github.com/njvack/bioread
```

- This MATLAB adaptation is distributed under the MIT license terms in `matlabBioread/LICENSE`.
- Keep both `matlabBioread/COPYRIGHT` and `matlabBioread/LICENSE` when copying this folder into another repository.

## Notes
- This implementation is fully local MATLAB (no Python dependency).
- `biopacReader(..., 'channelIndexes', [..])` uses MATLAB 1-based indexes.
- Optional flags in `biopacReader.read`:
  - `'includeUpsampledData'` (default `false`)
  - `'includeTimeIndex'` (default `false`)
- `biopacReader.readLoadAcq(...)` returns a struct with:
  - `hdr.per_chan_data`: channel header-style struct array.
  - `data`: table with one variable per channel; each cell stores that channel's `1xN` data array.
- Current parser support targets AcqKnowledge file revisions 4+ (revision `>= 61`).
