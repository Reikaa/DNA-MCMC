classdef PoreMC < handle

    properties
        % loaded values from csv
        Rs
        Zs
        Vs
        Is
        % gridded interpolant of above
        Vfun
        Ifun
        % pore outline points
        PoreRs
        PoreZs
        % anchor point (if present)
        AnchorZ
        % Sim parameters
        Params
        % output arrays
        Xs
        Bases
        Blocks
        % and current values
        X
        U
        Index
        % statistics tracking
        StepsAcc
        StepsTot
    end
    
    properties (Hidden,Constant)
        % 1 kT/nm =  4.114 pN
        pNperkT = 4.114;
        kTperpN = 1/PoreMC.pNperkT;
        eVperkT = 0.027;
    end
    
    methods
        function obj = PoreMC(varargin)
            
            % now load/validate all of the parameters
            p = inputParser;
            
            % no required arguments
            % optional sequence argument goes first, no name
            addOptional(p,'sequence',repmat('A',[1 100]),@ischar);
            
            % then all of our named parameter arguments
            % these are the MCMC parameters
            addParameter(p,'samples',1000,@isnumeric);
            addParameter(p,'burnin',100,@isnumeric);
            addParameter(p,'thin',4,@isnumeric);
            % and these are the DNA parameters
            addParameter(p,'linklength',0.5,@isnumeric);
            addParameter(p,'persistence',1.6,@isnumeric);
            addParameter(p,'eperbase',0.5,@isnumeric);
            addParameter(p,'V',0.14,@isnumeric);
            % this is in kT/nm^2 or such, from Dessinges et al.
            addParameter(p,'kstretch',120,@isnumeric);
            % DNA-pore interaction energy
            addParameter(p,'uinter',[0 0 0 0],@isnumeric);
            % and interaction distance falloff
            addParameter(p,'dinter',0.2,@isnumeric);
            % also give it a bead radius that the top end is pinned to
            addParameter(p,'rbead',4,@isnumeric);
            % and let us choose the name if we want
            addParameter(p,'poretype','biopore',@ischar);
            % set an anchor point if we have one
            addParameter(p,'anchor',nan,@isnumeric);
            
            parse(p,varargin{:});
            obj.Params = p.Results;
            
            % load precalculated voltages from COMSOL-generated csv
            % assumes fmt (r,z,V)
            fn = ['C:\Users\Tamas\Dropbox\research\calculations\comsol\' obj.Params.poretype '.csv'];
            data = csvread(fn);

            obj.Rs = unique(data(:,1));
            obj.Zs = unique(data(:,2));

            obj.Params.sequence = nt2int(obj.Params.sequence);
            obj.Params.N = numel(obj.Params.sequence);
            obj.Params.eperlink = obj.Params.eperbase*2 ...
                            *obj.Params.linklength; % ~2 bases/nm
            obj.Params.kbend = obj.Params.persistence/obj.Params.linklength;
            
            
            % scale Vs and Is by the given potential
            obj.Vs = obj.Params.V * reshape(data(:,3),[numel(obj.Rs),numel(obj.Zs)]);
            obj.Is = obj.Params.V * reshape(data(:,4),[numel(obj.Rs),numel(obj.Zs)]);
            % divide current density by max val
            obj.Is = obj.Is / max(max(obj.Is));
            % and make gridded functions
            obj.Vfun = griddedInterpolant({obj.Rs,obj.Zs},obj.Vs);
            obj.Ifun = griddedInterpolant({obj.Rs,obj.Zs},obj.Is);
            
            % now parse into pore opening outline
            vn = isnan(obj.Vs);
            nan0 = find(any(vn,1),1,'first');
            nan1 = find(any(vn,1),1,'last');
            nanmid = find(any(vn,2),1,'first');
            r0 = obj.Rs(find(vn(:,nan0),1,'first'));
            r1 = obj.Rs(find(vn(:,nan1),1,'first'));
            rmid = obj.Rs(nanmid);
            z0 = obj.Zs(nan0);
            z1 = obj.Zs(nan1);
            zmid = 0;

            obj.PoreRs = [r0+10, r0, rmid, r1, r1+10];
            obj.PoreZs = [z0, z0, zmid, z1, z1];
            
            % calculate bead top pos
            obj.Params.zbead = sqrt(obj.Params.rbead^2-r1^2)+z1;
            
            % if we're anchored, no bead radius and set bead z
            if ~isnan(obj.Params.anchor)
                obj.Params.zbead = obj.Params.anchor;
                obj.Params.rbead = 1;
            end
            
            % make big 3d array to hold configurations
            obj.Xs = zeros([obj.Params.samples, obj.Params.N, 3]);
            obj.Bases = zeros(obj.Params.samples,1);
            obj.Blocks = zeros(obj.Params.samples,1);
            % and initialize current config
            obj.X = zeros(obj.Params.N,3);
            % to a line at r = 0
            obj.X(:,3) = -(0:obj.Params.N-1)*obj.Params.linklength + ...
                obj.Params.zbead - 0.4*obj.Params.rbead;
            % get the energy
            obj.U = obj.Utotal(obj.X);
            
            obj.Index = 0;
            
            % stats
            obj.StepsAcc = [0 0 0];
            obj.StepsTot = [0 0 0];
            
        end
        
        
        function Plot(obj, hax)
            
            if nargin < 2
                %figure(1);
                clf
                hax = axes();
            end
            
            % plot two pore halves
            fill(obj.PoreRs,obj.PoreZs,[0.5 0.8 0.2],'Parent',hax);
            hold on
            fill(-obj.PoreRs,obj.PoreZs,[0.5 0.8 0.2],'Parent',hax);
            % the strand
            plot(hax,obj.X(:,1),obj.X(:,3),'k');
            % and the bead
            ths = linspace(0,2*pi,41);
            plot(obj.Params.rbead*cos(ths), ...
                obj.Params.rbead*sin(ths) + sqrt(obj.Params.rbead^2 ...
                - norm(obj.X(1,1:2))) + obj.X(1,3));
            
            %xlim(100*[-1 1]);
            %ylim([-100 100]);
            daspect([1 1 1])
            hold off
            drawnow
        end
        
        function rz = getRZ(~,x)
            rz = [sqrt(sum(x(:,1:2).^2,2)), x(:,3)];
        end
        
        function u = Utotal(obj,x)
            
            % first, bead-boundary check
            if norm(x(1,:)-[0,0,obj.Params.zbead]) > obj.Params.rbead
                u = 1e100;
                return
            end
            % vector of displacements
            dx = diff(x);
            % and their lengths
            ds = sqrt(sum(dx.^2,2));
            % stretching contribution to energy
            u = 0.5*obj.Params.kstretch*sum((ds-obj.Params.linklength).^2);
            % unit vector displacements
            ts = dx./repmat(ds,[1,3]);
            % and bending contribution
            u = u - obj.Params.kbend*sum(sum(ts(1:end-1,:).*ts(2:end,:)));
            % and finally get the work
            uw = sum(obj.Vfun(obj.getRZ(x)));
            % this is in volts
            % now multiply it by effective charge per link
            uw = uw * obj.Params.eperlink;
            % now it is in eV, convert to kT
            uw = uw / PoreMC.eVperkT;
            u = u + uw;
            if (isnan(u))
                u = 1e100;
            end
            % now interactions
            if any(obj.Params.uinter ~= 0)
                dinters = exp(-0.5*(x(:,3)/obj.Params.dinter).^2);
                uinters = obj.Params.uinter(obj.Params.sequence)*dinters;
                u = u + uinters;
            end
            
        end
        
        function SingleStep(obj)
            
            % random x proposal distribution, based on stretchiness and stuff
            delta = 0.2*sqrt(2/obj.Params.kstretch);
            dscale = [1 1 4];
            % random rotation angle scaling
            dtheta = 0.05*sqrt(2/obj.Params.kbend);
            % crankshaft angle step size, go all out
            dcrank = 2*pi;

            % propose new configuration
            Xnew = obj.X;

            % shorthand, cause Matlab
            N = obj.Params.N;

            % pick from various steps
            p = rand();
            if (p < 0.33)
                % randomly perturb (displace) a handful of beads
                for k=1:5
                    ii = sort(randi(N,1,2));
                    xt = Xnew(ii(1):ii(2),:);
                    drand = (rand(1,3)-0.5).*dscale;
                    xt = xt + 2*delta*repmat(drand,[size(xt,1),1]);
                    Xnew(ii(1):ii(2),:) = xt;
                end
                mtype = 1;
            elseif (p < 0.66)
                % pick random bead to perturb around
                ii = sort(randi(N,1,2));
                % get random rotation matrix
                R = rot_rand(dtheta);
                % and choose which direction (only front half if not
                % anchored)
                if rand() < 0.5 && obj.Params.rbead > 0
                    % front half of chain
                    ii(1) = 1;
                    % subset to be moved
                    xt = Xnew(ii(1):ii(2),:);
                    % and stuff
                    x0 = repmat(Xnew(ii(2),:),[size(xt,1), 1]);
                else
                    % back half of chain
                    ii(2) = size(Xnew,1);
                    xt = Xnew(ii(1):ii(2),:);
                    x0 = repmat(Xnew(ii(1),:),[size(xt,1), 1]);
                end
                % rotate the rest of the chain
                Xnew(ii(1):ii(2),:) = x0 + (xt-x0)*R;
                mtype = 2;
            else
                % pick random bead to perturb around
                ii = sort(randi(N,1,2));
                while diff(ii) < 2
                    ii = sort(randi(N,1,2));
                end
                % get the axis between them
                axis = diff(Xnew(ii,:));
                % and normalize it
                axis = axis/norm(axis);
                % create random rotation matrix along that axis
                R = rot_aa(axis,2*(rand()-0.5)*dcrank);
                % rotate the rest of the chain. doing it this way to make it easier to
                % keep end fixed
                xt = Xnew(ii(1):ii(2),:);
                x0 = repmat(Xnew(ii(1),:),[size(xt,1), 1]);
                Xnew(ii(1):ii(2),:) = x0 + (xt-x0)*R;
                mtype = 3;
            end

            % now calculate and compare energies
            Unew = obj.Utotal(Xnew);

            if rand() < exp(obj.U-Unew)
                % accept proposal
                obj.X = Xnew;
                obj.U = Unew;
                obj.StepsAcc(mtype) = obj.StepsAcc(mtype) + 1;
            end
            obj.StepsTot(mtype) = obj.StepsTot(mtype) + 1;

        end
        
        function isDone = Next(obj)
            
            % Takes a single output step, consists of N*thin baby steps
            
            isDone = false;
            
            % (except if no burnin yet, does a burnin first)
            if obj.Index == 0
                for i=1:obj.Params.burnin*obj.Params.thin*obj.Params.N
                    obj.SingleStep();
                end
                obj.Index = 1;
            elseif obj.Index > obj.Params.samples
                isDone = true;
                return
            end
            
            for i=1:obj.Params.thin*obj.Params.N
                obj.SingleStep();
            end
            obj.Xs(obj.Index,:,:) = obj.X;
            % weighted avg.
            %obj.Blocks(obj.Index) = sum(dinters);
            %obj.Blocks(obj.Index) = sum(obj.Ifun(obj.getRZ(obj.X)));
            % interaction/blockage stuff, not that useful
            minind = find(obj.X(:,3)>0,1,'last');
            dx = diff(obj.X);
            ts = dx./repmat(sqrt(sum(dx.^2,2)),[1,3]);
            obj.Blocks(obj.Index) = 1 - abs(ts(minind,3)).^2;
            
            %dinters = exp(-0.5*(obj.X(:,3)/0.3).^2);
            %dinters = dinters / sum(dinters);
            %obj.Bases(obj.Index) = sum(dinters.*(1:numel(dinters))');
            obj.Bases(obj.Index) = obj.Params.linklength*(minind - ...
                                        obj.X(minind,3)/diff(obj.X(minind:minind+1,3)));
            fprintf('Mean: %0.1f, Std: %0.2f, Accs: %0.2f,%0.2f,%0.2f\n', ...
                mean(obj.Bases(1:obj.Index)),std(obj.Bases(1:obj.Index)), ...
                obj.StepsAcc ./ obj.StepsTot);
            obj.Index = obj.Index + 1;
            
        end

    end
    
end

