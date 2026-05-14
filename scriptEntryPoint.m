participantDirPath = "...\0-Data\1-RawData";

taskSegmentation = struct('name', {}, 'events', {});

pipelineEnv = setupPipelineEnvironment(); %#ok<NASGU>

participantsFiles = string({dir(fullfile(participantDirPath, "*.acq")).name}).';
participants = erase(participantsFiles, ".acq");

for i = 1:length(participants)
    participantFile = participants(i) + ".acq";
    participantDataPath = fullfile(participantDirPath, participantFile);
    participant = Participant(participantDataPath);
    participant.runPreprocessing( ...
        save=true, ...
        ecgArtifactRejectionMethod="semiauto", ...
        taskSegmentation=taskSegmentation, ...
        sourcesToExtract=["ECG","EDA"]);
end
