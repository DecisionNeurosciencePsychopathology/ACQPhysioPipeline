function env = setupPipelineEnvironment()

    scriptDir = fileparts(mfilename('fullpath'));
    originalDir = pwd;

    env = struct();
    env.scriptDir = scriptDir;
    env.originalDir = originalDir;
    env.restoreCwd = onCleanup(@() cd(originalDir));

    cd(scriptDir);
    addpath(genpath(fullfile(scriptDir, 'utils')));

end
