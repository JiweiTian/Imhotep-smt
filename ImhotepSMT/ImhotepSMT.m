%  * Copyright (c) 2015 The Regents of the University of California.
%  * All rights reserved.
%  *
%  * Redistribution and use in source and binary forms, with or without
%  * modification, are permitted provided that the following conditions
%  * are met:
%  * 1. Redistributions of source code must retain the above copyright
%  *    notice, this list of conditions and the following disclaimer.
%  * 2. Redistributions in binary form must reproduce the above
%  *    copyright notice, this list of conditions and the following
%  *    disclaimer in the documentation and/or other materials provided
%  *    with the distribution.
%  * 3. All advertising materials mentioning features or use of this
%  *    software must display the following acknowledgement:
%  *       This product includes software developed by Networked &
%  *       Embedded Systems Lab at UCLA
%  * 4. Neither the name of the University nor that of the Laboratory
%  *    may be used to endorse or promote products derived from this
%  *    software without specific prior written permission.
%  *
%  * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS''
%  * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
%  * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
%  * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE REGENTS
%  * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%  * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
%  * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
%  * USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%  * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
%  * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
%  * OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%  * SUCH DAMAGE.
%  *
%  * Developed by: Yasser Shoukry
%  */

classdef ImhotepSMT  < handle
    %=============================================
    properties
        isLinear        = 1;        % 1 = linear solver, 2 = nonlinear solver
        tolerance       = 1E-5;     % mathemtical tolerance
        maxIterations   = 1000;
    end
    properties (SetAccess = private)
        sys             = []    % system dynamics
        safeSensors     = []    % set of safe sensors
        n               = 0     % number of states
        p               = 0     % number of outputs
        m               = 0     % number of inputs
        s               = 0     % max number of attacked sensors
        tau             = 0     % window length
        Y_tilde         = {}    % cell array of sensor measurements
        Y               = {}    % cell array of outputs buffers
        U               = []    % input buffer
        O               = {}    % cell array of different observability matrix
        F               = {}    % cell array of input matrix
        dimNull         = []    % dimension of the null(O)
        noiseBound      = []    % noise bounds for individual sensors
        
        bufferCounter   = 0     % counter to indicate if the buffers now full
        
        conflictClauses = {}    % set of conflcting learnt clauses
        agreeableClauses= {}    % set of agreeable learnt clause
        
        SATsolver       = [];   % instance of the SAT solver
        mumberOfTheoryCalls = 0;
        
        initialized     = -1;   % check if the solver is well initialized
        isSparseObservable = -1;% does the observability check pass through
        
        maxEstimationError= -1;  % the theoritical upper bound on estimation error
    end
    %=============================================
    properties (Hidden)
        EQUAL                   = 0;
        LESS_THAN_OR_EQUAL      = -1;
        LESS_THAN               = -2;
        GREATER_THAN_OR_EQUAL   = 1;
        GREATER_THAN            = 2;
        delta_s                 = 0;    % delta is a parmeter which is used to calculate the max bound
        o_bar                   = 0;    % o_bar is a parmeter which is used to calculate the max bound
    end
    %=============================================
    methods
        function smt = ImhotepSMT()
            javapath = javaclasspath;
             if(isempty(javapath))
                ImhotepFilepath=fileparts(which('ImhotepSMT.m')); 
                SAT4J_PATH = 'SAT4J';
                javaaddpath(fullfile(ImhotepFilepath, SAT4J_PATH,'org.sat4j.core.jar'));
                javaaddpath(fullfile(ImhotepFilepath, SAT4J_PATH,'org.sat4j.pb.jar'));
                javaaddpath(fullfile(ImhotepFilepath, SAT4J_PATH,'org.sat4j.maxsat.jar'));
                javaaddpath(fullfile(ImhotepFilepath, SAT4J_PATH,'sat4j-sat.jar'));
                javaaddpath(fullfile(ImhotepFilepath, SAT4J_PATH,'sat4j-pb.jar'));
                javaaddpath(fullfile(ImhotepFilepath, SAT4J_PATH,'sat4j-maxsat.jar'));
             end
            % discard some warning messages
            warning('off','MATLAB:rankDeficientMatrix') ;
            warning('off','MATLAB:nearlySingularMatrix') ;
            warning('off','MATLAB:singularMatrix') ;
            warning('off', 'MATLAB:nchoosek:LargeCoefficient');
        end
        %------------------------
        function status = init(obj, sys, maxNumberOfAttackedSensors, safeSensors, noiseBound)
            if(obj.initialized == 1)
                disp('WARNING: Solver is already initialized. Ignoring this method call!')
                status = 1;
                return;
            end
            
            obj.isLinear        = 1;
            %1) Check the type of the first argument
            if(isa(sys,'ss') == 0)
                disp(['ERROR: First argument of init() is not of type "ss".' char(13) 
                'Please specify the dynamics of your system properly']);
                status = -1;
                obj.initialized = -1;
                return; 
            end
            if(isinteger(maxNumberOfAttackedSensors) == 0)
                disp('ERROR: Second argument of init() must be of integer type')
                status = -1;
                obj.initialized = -1;
                return; 
            end
            
            %2) Copy the system specification and extract the dimensions
            obj.sys                     = sys;
            obj.n                       = size(sys.A,1); 
            obj.p                       = size(sys.C,1); 
            obj.m                       = size(sys.B,2);
            obj.s                       = double(maxNumberOfAttackedSensors); 
            obj.tau                     = obj.n;
            obj.bufferCounter           = 0;
            if(obj.s > 0)
                obj.maxIterations           = 2*nchoosek(obj.p, obj.p-2*obj.s+1) + 1;
            end
            obj.U                       = zeros(obj.tau*obj.m,1);
            for sensorIndex = 1 : obj.p
                F_temp = zeros(1,obj.m*obj.tau);
                for counter = 2 : obj.tau
                    F_temp(counter,:) = [obj.sys.C(sensorIndex,:)*obj.sys.A^(counter-2)*obj.sys.B F_temp(counter-1,1:end-obj.m)];
                end
                obj.F{sensorIndex} = F_temp;
            end
            
            %3) Check that the second argument has the correct dimensions
            %and all its components are positive
            if(size(noiseBound,2) > size(noiseBound,1))
                noiseBound              = noiseBound';
            end
            if(sum(size(noiseBound) ~= [obj.p,1]) > 0)
                disp(['ERROR: The noise bound vector must be ' num2str(obj.p) 'x 1']);
                status                  = -1;
                obj.initialized         = -1;
                return;
            else
                for sensorIndex = 1 : obj.p
                    if(noiseBound(sensorIndex) < 0)
                        disp(['ERROR: Noise bound for sensor#' num2str(sensorIndex) ' must be positive number.']);
                        status          = -1;
                        obj.initialized = -1;
                        return;                
                    end
                    obj.noiseBound(sensorIndex) = noiseBound(sensorIndex);
                end 
            end
            
            %4) Check that the set of safe sensors are all less than obj.p
            if(max(safeSensors) > obj.p)
                disp(['ERROR: Largest index of safe sensors must be less than ' num2str(obj.p) '.']);
                status = -1;
                obj.initialized = -1;
                return;  
            end
            obj.safeSensors             = safeSensors;
            
            for counter = 1 : length(obj.safeSensors)
                obj.markSensorAsSafe(obj.safeSensors(counter));
            end
            
            %5) Calculate the observability matrix along with the
            %dimension of the null space.
            for sensorIndex = 1 : obj.p
                obj.O{sensorIndex}          = obsv(obj.sys.A, obj.sys.C(sensorIndex,:));
                obj.dimNull(sensorIndex)    = obj.n - rank(obj.O{sensorIndex});
                obj.Y{sensorIndex}          = zeros(obj.tau,1);
                obj.Y_tilde{sensorIndex}    = zeros(obj.tau,1);
            end
            
            %6) Analyze the structure of the system and check the upper
            %bound on the "maximum number of attacked sensors"
            status                          = obj.analyzeSystemStructure();
            if(status == -1)
                return;
            end
            
            %7) Initalize the SAT solver
            obj.mumberOfTheoryCalls         = 0;
            numberOfBooleanVariables        = obj.p;
            numberOfConvexConstraints       = obj.p;
            
            obj.agreeableClauses            = {};
            obj.conflictClauses             = {};
            
            numberOfVariables               = numberOfBooleanVariables + numberOfConvexConstraints;
            numberOfConstraints             = numberOfConvexConstraints + 1 + length(obj.conflictClauses);

            obj.SATsolver                   = org.sat4j.pb.SolverFactory.newLight();
            obj.SATsolver.newVar(numberOfVariables);
            obj.SATsolver.setExpectedNumberOfClauses(numberOfConstraints);
            
            %8) All initializations are going well
            obj.initialized                 = 1;
        end
        %------------------------
        function status = initNonLinearSolver(obj, nlsys, maxNumberOfAttackedSensors, safeSensors, noiseBound)
            if(obj.initialized == 1)
                disp('WARNING: Solver is already initialized. Ignoring this method call!')
                status = 1;
                return;
            end
            
            obj.isLinear        = 2;
            %1) Check the type of the first argument
            if(isa(nlsys,'nlsys') == 0)
                disp(['ERROR: First argument of init() is not of type "nlsys".' char(13) 
                'Please specify the dynamics of your system properly']);
                status = -1;
                obj.initialized = -1;
                return; 
            end
            if(isinteger(maxNumberOfAttackedSensors) == 0)
                disp('ERROR: Second argument of initNonLinearSolver() must be of integer type')
                status = -1;
                obj.initialized = -1;
                return; 
            end
            
            %2) Copy the system specification and extract the dimensions
            obj.sys                     = nlsys;
            obj.n                       = nlsys.n; 
            obj.p                       = nlsys.p; 
            obj.m                       = nlsys.m;
            obj.s                       = double(maxNumberOfAttackedSensors); 
            obj.tau                     = nlsys.tau;
            obj.bufferCounter           = 0;
            if(obj.s > 0)
                obj.maxIterations       = 2*nchoosek(obj.p, obj.p-2*obj.s+1) + 1;
            end
            for inputCounter = 1 : obj.m
                obj.U{inputCounter}     = zeros(obj.tau,1);
            end
            
            
            
            %3) Check that the second argument has the correct dimensions
            %and all its components are positive
            if(size(noiseBound,2) > size(noiseBound,1))
                noiseBound              = noiseBound';
            end
            if(sum(size(noiseBound) ~= [obj.p,1]) > 0)
                disp(['ERROR: The noise bound vector must be ' num2str(obj.p) 'x 1']);
                status                  = -1;
                obj.initialized         = -1;
                return;
            else
                for sensorIndex = 1 : obj.p
                    if(noiseBound(sensorIndex) < 0)
                        disp(['ERROR: Noise bound for sensor#' num2str(sensorIndex) ' must be positive number.']);
                        status          = -1;
                        obj.initialized = -1;
                        return;                
                    end
                    obj.noiseBound(sensorIndex) = noiseBound(sensorIndex);
                end 
            end
            
            %4) Check that the set of safe sensors are all less than obj.p
            if(max(safeSensors) > obj.p)
                disp(['ERROR: Largest index of safe sensors must be less than ' num2str(obj.p) '.']);
                status = -1;
                obj.initialized = -1;
                return;  
            end
            obj.safeSensors             = safeSensors;
            
            for counter = 1 : length(obj.safeSensors)
                obj.markSensorAsSafe(obj.safeSensors(counter));
            end
            
            %5) Calculate the observability matrix along with the
            %dimension of the null space.
            for sensorIndex = 1 : obj.p
                obj.Y{sensorIndex}          = zeros(obj.tau,1);
                obj.dimNull(sensorIndex)    = 1;    % dummy number to skip the ordering based on the kernel
                obj.O{sensorIndex}          = 0;    % dummy number
            end
            
            %6) Analyze the structure of the system and check the upper
            %bound on the "maximum number of attacked sensors"
%             status                          = obj.analyzeSystemStructure();
%             if(status == -1)
%                 return;
%             end
            
            %7) Initalize the SAT solver
            obj.mumberOfTheoryCalls         = 0;
            numberOfBooleanVariables        = obj.p;
            numberOfConvexConstraints       = obj.p;
            
            obj.agreeableClauses            = {};
            obj.conflictClauses             = {};
            
            numberOfVariables               = numberOfBooleanVariables + numberOfConvexConstraints;
            numberOfConstraints             = numberOfConvexConstraints + 1 + length(obj.conflictClauses);

            obj.SATsolver                   = org.sat4j.pb.SolverFactory.newLight();
            obj.SATsolver.newVar(numberOfVariables);
            obj.SATsolver.setExpectedNumberOfClauses(numberOfConstraints);
            
            %8) All initializations are going well
            obj.initialized                 = 1;
        end
        %------------------------
        function status = checkObservabilityCondition(obj)
            obj.o_bar = 0;
            
            if(obj.initialized == -1)
                disp('ERROR: The solver is not initalized yet. To initialize the solver, call the init() method');
                status = -1;
                return;
            end
            
            if(obj.s == 0)
                disp('The maximum number of sensors under attack is 0. Abort');
                status = 0;
                return;
            end
            
            max_count                   = nchoosek(obj.p, obj.p - length(obj.safeSensors) - 2*obj.s);
            allCombinations             = combnk(setdiff(1:obj.p, obj.safeSensors), 2*obj.s);
            disp(' ');
            disp('INFO: The sparse observability test ensures that the system is observable');
            disp(['after removing every combination of ' num2str(2*obj.s) ' sensors. This requires']);
            disp(['checking the observability of ' num2str(max_count) ' combinations ... This may take some time']);
            observable = 1;
            disp(' ');
            for counter = 1 : max_count
                sensorsIdx = setdiff(1:obj.p, allCombinations(counter,:));
                O_temp = obsv(obj.sys.A, obj.sys.C(sensorsIdx,:));
                if(rank(O_temp) < obj.n )
                    observable = 0;
                    disp(['Iteration number ' num2str(counter) ' out of ' num2str(max_count) ' combinations ... FAIL!']);
                    break;
                else
                    maxEigValue = norm(pinv(O_temp));
                    if(maxEigValue > obj.o_bar)
                        obj.o_bar = maxEigValue;
                    end
                end
                disp(['Iteration number ' num2str(counter) ' out of ' num2str(max_count) ' combinations ... PASS!']);
            end
            if(observable == 0)
                disp('Sparse observability condition failed. Re-initialize the solver by calling init().');
                status                  = -1;
                obj.isSparseObservable  = -1;
                obj.initialized         = -1;
                return;
            else
                disp('Sparse observability condition passed! Solver is ready to run!');
                status                  = 1;
                obj.isSparseObservable  = 1;
                obj.initialized         = 1;
            end
        end
        %------------------------
        function maxEstimationError = calculateMaxEstimationError(obj)
            obj.delta_s = 0;
            if(obj.isSparseObservable  == 0)
                disp(['System is not s-sparse observable, max. estimation error = ' num2str(inf)]);
                obj.maxEstimationError = inf;
            elseif(obj.isSparseObservable  == 1)
                O_all = obsv(obj.sys.A, obj.sys.C);
                O_all_inv = inv(O_all'*O_all);
                for counter = 1 : obj.p
                    O_rest = obsv(obj.sys.A, obj.sys.C(setdiff(1:obj.p, counter)));
                    maxEigValue = max(eig((O_rest'*obj.O{counter})*O_all_inv));
                     if(obj.delta_s < maxEigValue)
                         obj.delta_s = maxEigValue;
                     end
                end
                obj.maxEstimationError = sqrt(2*obj.o_bar*(1 + 2/(1 - obj.delta_s))*norm(obj.noiseBound)^2 + 2*obj.o_bar*obj.tolerance/(1 - obj.delta_s));
            else
                disp('Please run the s-sparse observability test first. To run this test, call checkObservabilityCondition()');
                obj.maxEstimationError = -1;
            end
            
            maxEstimationError = obj.maxEstimationError;
        end
        %------------------------
        function [xhat, sensorsUnderAttack, status ]= addInputsOutputs(obj, inputs, measurments)
            status = -1; 
            xhat = zeros(obj.n,1);
            sensorsUnderAttack = [];
            
            if(sum(size(inputs) == [obj.m, 1]) < 2)
                disp(['ERROR: Check dimension of the inputs vector. Inputs vector must be a (' num2str(obj.m) 'x1) vector']);
                return;
            end
            if(size(measurments,2) ~= 1 || size(measurments,1) ~= obj.p)
                disp(['ERROR: Check dimension of the measurments vector (Y). Measurments vector (Y) must be a (' num2str(obj.p) 'x1) vector'])
                return;
            end
%             
%             for inputCounter = 1 : obj.m
%                 UU                                  = obj.U(inputCounter);
%                 obj.U(inputCounter)                 = [UU(2:end); inputs(inputCounter)];
%             end
            %TBD
            obj.U                   = [obj.U(obj.m+1:end); inputs];
            
            if(obj.isLinear == 1)
                for sensorIndex = 1 : obj.p
                    YY                                = obj.Y_tilde{sensorIndex};
                    obj.Y_tilde{sensorIndex}          = [YY(2:end); measurments(sensorIndex)];
                    obj.Y{sensorIndex}                = obj.Y_tilde{sensorIndex} - obj.F{sensorIndex}*obj.U;
                end
            else
                for sensorIndex = 1 : obj.p
                    YY                                = obj.Y{sensorIndex};
                    obj.Y{sensorIndex}                = [YY(2:end); measurments(sensorIndex)];
                end
            end
            
            
            if(obj.bufferCounter <= obj.tau)
                obj.bufferCounter                 =   obj.bufferCounter + 1;
            end
            % Is the buffers full ?
            if(obj.bufferCounter >= obj.tau)
                [xhat, sensorsUnderAttack, status ]         = obj.solve();
                if(isempty(xhat) == 1)
                    return;
                end
                % run the estimate forward in time
                if(obj.isLinear == 1)
                    for counter = 1 : obj.tau
                        xhat = obj.sys.A*xhat + obj.sys.B*obj.U((counter-1)*obj.m + 1: (counter-1)*obj.m  +obj.m);
                    end
                else
%                     for counter = 1 : obj.tau
%                         xhat = obj.sys.f(xhat, obj.U((counter-1)*obj.m + 1: (counter-1)*obj.m  +obj.m));
%                     end
                end
            end
        end
        %------------------------
        function flushBuffers(obj)
            obj.U                           = zeros(obj.tau*obj.m,1);
            for sensorIndex = 1 : obj.p
                obj.Y{sensorIndex}          = zeros(obj.tau,1);
                obj.Y_tilde{sensorIndex}    = zeros(obj.tau,1);
            end
            obj.bufferCounter               = 0;
        end
        %------------------------
    end
    %========================================
    % Helper (private) methods
    %========================================
    methods (Access = private)
        function status = analyzeSystemStructure(obj)
            status          = -1;
            if(obj.s < 0)
                disp('ERROR: the specified "number of sensors under attack" must be positive');
                return;
            end
            
            OO_upper        = [];
            
            for sensorIndex = 1 : obj.p
                OO_temp     = sum(obj.O{sensorIndex}, 1);
                OO_upper    = [ OO_upper; (OO_temp > 0) + (OO_temp < 0)];
            end
            
            % 1-Theoritical upper bound
            idx             = [];
            for counter = 1 : length(obj.safeSensors)
                idx = [idx find(OO_upper(obj.safeSensors(counter),:) == 1)];
            end
            unsafeStates        = setdiff(1:obj.n, idx);
            stateSecurityIndex  = sum(OO_upper(:,unsafeStates), 1);
            
            if(isempty(stateSecurityIndex))
                s_upper_bound   = obj.p - length(obj.safeSensors);
            else
                s_upper_bound   = floor((min(stateSecurityIndex) - 1)/2);
            end
            
            
            if(s_upper_bound < 0 )
                s_upper_bound = 0;
            end
            disp(' ');
            disp( ['The maximum number of attacks specified by the user is: ' num2str(obj.s)]);
            disp( ['Theoretical upper bound on maximum number of attacks is: ' num2str(s_upper_bound)]);
            
            
            % 2-structure of sensors
            index           = find(stateSecurityIndex == min(stateSecurityIndex), 1, 'first');
            sensorIndex     = find(OO_upper(:,index) == 1);
            
            
            
            disp(' ');
            if(s_upper_bound < obj.s)
                disp('ERROR: System structure does not match the maximum number of attacked sensors specified by the user');
                if(isempty(sensorIndex) == 0)
                    reportStr2      = 'Sensors that can improve system security are: ';
                    for counter = 1 : length(sensorIndex)
                        reportStr2 = [reportStr2 'Sensor#' num2str(sensorIndex(counter)) ' '];
                    end
                    disp(' ');
                    disp(reportStr2);
                end
            
                status      = -1;
                return;
            elseif(obj.s > 0)
                disp('Disclaimer: Correction of the solver outputs is guaranteed if and only if');
                disp('the system passes the s-sparse observability test. To run this combinatorial test,');
                disp('call the checkObservabilityCondition()');
            else
                disp('Warning: This system is configured with maximum number of attacks = 0.');
                status      = 0;
                return;
            end
            status          = 1;
        end
        %------------------------
        function markSensorAsSafe(obj, sensorIndex)
            obj.agreeableClauses{end+1} = sensorIndex;
        end
        %------------------------
        function  [xhat, sensorsUnderAttack, status ] = solve(obj)
            status = 1;
            xhat = [];
            sensorsUnderAttack = [];
            
            obj.agreeableClauses = {};
            obj.conflictClauses  = {};
            
            for counter = 1 : length(obj.safeSensors)
                obj.markSensorAsSafe(obj.safeSensors(counter));
            end
            
            if(obj.initialized == -1)
                disp('ERROR: Solver is NOT initialized.');
                status = -1;
                obj.flushBuffers();
                return;
            end
            
            solved = 0;
            obj.mumberOfTheoryCalls = 0;
            while solved == 0 || obj.mumberOfTheoryCalls >= obj.maxIterations
                try
                    obj.writeConstriantsToSAT();
                catch e
                    disp('ERROR: Something went wrong .. Flush the buffers');
                    status = -1;
                    obj.flushBuffers();
                    return;
                end
                obj.mumberOfTheoryCalls    = obj.mumberOfTheoryCalls + 1;
                
                % Get the boolean assignment
                status = obj.SATsolver.isSatisfiable();
                if(status == 0)
                    status = -1;
                    disp('ERROR: System is UNSAT. Check the system parameters and measurements.');
                    return
                end
              
                convexConstraintAssignment  = obj.SATsolver.model;
                constraints         = find(convexConstraintAssignment < 0);
                sensorsUnderAttack  = find(convexConstraintAssignment > 0);
                
                Y_active = []; O_active = [];
                for counter = 1 : length(constraints)
                    Y_active = [Y_active; obj.Y{constraints(counter)}];
                    O_active = [O_active; obj.O{constraints(counter)}];
                end
                
                
                % Calculate the individual slack vriables
                slack = zeros(1,obj.p);
                if(obj.isLinear == 1)
                    % Formalize the Convex optimization problem
                    %xhat = linsolve(O_active,Y_active);
                    xhat = O_active\Y_active;
                    for counter = 1 : length(constraints)
                        slack(constraints(counter)) = norm(obj.Y{constraints(counter)} - obj.O{constraints(counter)}*xhat);
                    end
                else
                    % Use the specified observer
                    [xhat, obsevStatus]     = obj.sys.observer(constraints, obj.Y, obj.U);
                    % for nonlinear systems, we compare the last
                    % output only not the whole vector
                    Y_active= [];
                    for sensorCounter = 1 : length(constraints)
                        yy       = obj.Y{constraints(sensorCounter)};
                        Y_active = [Y_active; yy(end)];
                    end

                    if(obsevStatus == 1)
                        y_hat   = obj.sys.h(xhat);
                        Y_hat   = y_hat(constraints);
                    else
                        Y_hat = Y_active; %hack to bypass the check below
                    end
                        
                        
                    for counter = 1 : length(constraints)
%                         Y_hat   = [];
%                         xx      = xhat;
% %                        for timeCounter = 1 : obj.tau
%                         y_hat   = obj.sys.h(xx);
%                         Y_hat   = [Y_hat; y_hat(constraints(counter))];
%                         Y_active= obj.Y{constraints(counter)};
% %                            xx      = obj.sys.f(xx, obj.U(obj.m*(timeCounter-1)+1:obj.m*timeCounter));
% %                        end
                        slack(constraints(counter)) = norm(Y_active(counter) - Y_hat(counter));
                    end
                end
                
                % Uncomment for debugging
                %constraints'
                %slack
                
                % Check if the convex constraints are SAT
                if sum(slack) <= obj.tolerance + sum(obj.noiseBound(constraints));
                    solved = 1;
                    return;
                end

                % If UNSAT, then add the conflict clause to the Problem
                foundConflict = 0;  conflicts = [];
                foundAgreeable = 0; agreeable = [];
                
                
                % 1- Sort based on slack
                [~, slackIndex] = sort(slack(constraints), 'ascend');
                slackIndex      = constraints(slackIndex);
                
                % 2- We know that at most s-sensors are under attack.
                % The worst case scenario is that all of them are 
                % present in the current assignment. So skip the highest
                % s-slack and for the rest, sort them according to their
                % diemnsion of null space. Remeber that the boolean
                % assignment already excluded s sensors. Now by excluding
                % more s sensors, we have (p - 2s) remaining sensors. From
                % the 2s-sparse observability condition we know that any
                % (2s - p) sensors are fully observable, i.e. their
                % observability matrix spans the full space.
                
                indexLowSlackSensors            = slackIndex(1 : end - obj.s);
                [~, indexSortedLowSlackSensors] = sort(obj.dimNull(indexLowSlackSensors), 'ascend');
                indexSortedLowSlackSensors      = indexLowSlackSensors(indexSortedLowSlackSensors);
                % Use tha (2s - p) sensors against the sensors with the max
                % slack to generate a short conflicting clause
                max_slack_index = slackIndex(end);
                
                
                % search linearly for a sensor that
                % conflicts with the max slack.
                Y_active = obj.Y{max_slack_index};
                O_active = obj.O{max_slack_index};
                Y_hat    = [];
                sensorList  = [max_slack_index];
                for counter = 1 : length(indexSortedLowSlackSensors)
                    sensor      = indexSortedLowSlackSensors(counter);
                    sensorList  = [sensorList, sensor];
                    Y_active    = [Y_active;  obj.Y{sensor}];
                    O_active    = [O_active;  obj.O{sensor}];
                    
                    if(obj.isLinear == 1)
                        % Formalize the Convex optimization problem
                        %xhat = linsolve(O_active,Y_active);
                        xhat  = O_active\Y_active;
                        Y_hat = O_active * xhat;
                    else
                        % Use the specified observer
                        [xhat, obsevStatus]    = obj.sys.observer(sensorList, obj.Y, obj.U);
                        if(obsevStatus == 1)
                            y_hat   = obj.sys.h(xhat);
                            Y_hat   = y_hat(sensorList);
                            % for nonlinear systems, we compare the last
                            % output only not the whole vector
                            Y_active= [];
                            for sensorCounter = 1 : length(sensorList)
                                yy       = obj.Y{sensorList(sensorCounter)};
                                Y_active = [Y_active; yy(end)];
                            end
                            
%                             xx      = xhat;
%                             
%                             for timeCounter = 1 : obj.tau
%                                 y_hat   = obj.sys.h(xx);
%                                 Y_hat   = [Y_hat y_hat(sensorList)];
%                                 xx      = obj.sys.f(xx, obj.U(obj.m*(timeCounter-1)+1:obj.m*timeCounter));
%                             end
%                             Y_hat       = reshape(Y_hat', length(sensorList)*obj.tau, 1);
                        else
                            Y_hat = Y_active; %hack to bypass the check below
                        end
                    end
                
                    if(norm(Y_active - Y_hat) > obj.tolerance + sum(obj.noiseBound(indexSortedLowSlackSensors(1:counter))) )
                        % Conflict discovered
                        conflicts = [max_slack_index, indexSortedLowSlackSensors(1:counter)'];
                        foundConflict = 1;
                        break;
                    end
                end

                % Just-in-case if the previous search failed, then use the
                % weakest clause
                if(foundConflict == 0)
                    %disp('ooops');
                    conflicts       = constraints;
                end
                obj.conflictClauses{end+1} = conflicts;
                
                % Search for agreeable constraints. The longest the better
                % start by lowest slack and go linearly until you find the
                % longest set of agreeable constraints
                if(obj.p > 3 * obj.s)
                    Y_active = []; O_active = []; Y_hat = [];
                    for counter = 1 : length(constraints)
                        sensor      = slackIndex(counter);
                        Y_active    = [Y_active;  obj.Y{sensor}];
                        O_active    = [O_active;  obj.O{sensor}];
                        obsevStatus = 1;
                        if(obj.isLinear == 1)
                            % Formalize the Convex optimization problem
                            %xhat = linsolve(O_active,Y_active);
                            xhat = O_active\Y_active;
                            Y_hat = O_active * xhat;
                        else
                            % Use the specified observer
                            if(obsevStatus == 1)
                                y_hat   = obj.sys.h(xhat);
                                Y_hat   = y_hat(sensorList);
                                % for nonlinear systems, we compare the last
                                % output only not the whole vector
                                Y_active= [];
                                for sensorCounter = 1 : length(sensorList)
                                    yy       = obj.Y{sensorList(sensorCounter)};
                                    Y_active = [Y_active; yy(end)];
                                end

    %                             xx      = xhat;
    %                             
    %                             for timeCounter = 1 : obj.tau
    %                                 y_hat   = obj.sys.h(xx);
    %                                 Y_hat   = [Y_hat y_hat(sensorList)];
    %                                 xx      = obj.sys.f(xx, obj.U(obj.m*(timeCounter-1)+1:obj.m*timeCounter));
    %                             end
    %                             Y_hat       = reshape(Y_hat', length(sensorList)*obj.tau, 1);
                            else
                                foundAgreeable = 0;
                                break;
                                %Y_hat = Y_active; %hack to bypass the check below
                            end
                        end
                        
                        
                        if(norm(Y_active - Y_hat) > obj.tolerance + sum(obj.noiseBound(slackIndex(1:counter))) )
                            % Conflict discovered
                            if(counter > obj.p - 2*obj.s)
                                agreeable = slackIndex(1:counter-1);
                                foundAgreeable = 1;
                            end
                            break;    
                        end
                    end
                    if(foundAgreeable)
                        obj.agreeableClauses{end+1} = agreeable;
                    end
                end   
            %-----------    
            end %while(solved)
            
            if solved == 0
                xhat = [];
                sensorsUnderAttack = [];
                disp('ERROR: Maximum number of iterations reached.');
                return;
            end
        end
        %------------------------
        function writeConstriantsToSAT(obj)
            % Add the optimization goal
            % minimize b1 + b2 + ... bp
            % TODO

            obj.SATsolver.reset();
            % Add the constraint on the number of attacks does not exceed s
            % i.e., b1 + b2 + ... + bp  <= s
            literals = []; coeffs = [];
            %calllib('CalCSminisatp','startNewConstraint')
            for counter = 1 : obj.p
                literals(end+1) = counter;
                coeffs(end+1) = 1;
            end
            litI = org.sat4j.core.VecInt(literals); 
            coefI = org.sat4j.core.VecInt(coeffs);
            obj.SATsolver.addAtMost(litI, coefI, obj.s);


            % Add the conflicting clauses
            %
            % conflict cluases take the form
            % b_i + b_j >= 1
            % which inforces that both of these sensors can not be
            % un-attacked at the same time. Either both are attacked (so
            % the SAT solver shall assign both to 1), or one of them under
            % attack while the other is not, the SAT solver is going to
            % assign 0 for one of them and 1 to the other.
            
            for counter = 1 : size(obj.conflictClauses,2)
                literals = []; coeffs = [];
                for counter2 = 1 : length(obj.conflictClauses{counter})
                    literals(end+1) = obj.conflictClauses{counter}(counter2);
                    coeffs(end+1) = 1;
                end
                litI = org.sat4j.core.VecInt(literals); 
                coefI = org.sat4j.core.VecInt(coeffs);
                obj.SATsolver.addAtLeast(litI, coefI, 1);
            end

            % Add the agreeable clauses
            %
            % agreeable cluases take the form
            % b_i + b_j == 0
            % which inforces that this set of sensors to be all in the
            % set of un-attacked sensors.
            
            for counter = 1 : size(obj.agreeableClauses,2)
                literals = []; coeffs = [];
                for counter2 = 1 : length(obj.agreeableClauses{counter})
                    literals(end+1) = obj.agreeableClauses{counter}(counter2);
                    coeffs(end+1) = 1;
                end
                litI = org.sat4j.core.VecInt(literals); 
                coefI = org.sat4j.core.VecInt(coeffs);
                obj.SATsolver.addExactly(litI, coefI, 0);
            end
        end
        %------------------------
    end
end