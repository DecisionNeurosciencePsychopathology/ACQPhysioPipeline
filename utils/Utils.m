classdef Utils <handle
    properties
    end
    methods
        function obj = Utils()
        end
    end
    
    methods(Static)

        function nv = packStructAsNameValuePairs(inputStruct)
                f = fieldnames(inputStruct);
                v = struct2cell(inputStruct);
                
                nv = cell(1,2*numel(f)); nv(1:2:end)=f; nv(2:2:end)=v;
        end

        function out = structOverwriteDeep(base, override)
            if nargin < 1 || isempty(base), base = struct(); end
            if nargin < 2 || isempty(override), override = struct(); end
            if ~isstruct(base) || ~isscalar(base) || ~isstruct(override) || ~isscalar(override)
                error('Inputs must be scalar structs.');
            end
            
            out = base;
            f = fieldnames(override);
            
            for k = 1:numel(f)
                n = f{k};
                if isfield(out,n) && isstruct(out.(n)) && isstruct(override.(n)) && isscalar(out.(n)) && isscalar(override.(n))
                    out.(n) = structOverwriteDeep(out.(n), override.(n));
                elseif isfield(out,n) 
                    out.(n) = override.(n);
                end
            end
        end
        
        function parametersForThisSource = getSourceParameters(srcObject,givenParams)
            % Default parameters
            if ismethod(srcObject, "getDefaultPreprocessParams")
                sourceDefaultParameters = srcObject.getDefaultPreprocessParams();
            else
                sourceDefaultParameters = struct();
            end
    
            % Override parameters with user-provided
            parametersForThisSource = Utils.structOverwriteDeep(sourceDefaultParameters, givenParams);
            parametersForThisSource = namedargs2cell(parametersForThisSource);
            
        end
        
        function out = mergeStructs(a,b)
            out = a;
            f = fieldnames(b);
            for i = 1:numel(f)
                out.(f{i}) = b.(f{i});
            end
        end
    end

end