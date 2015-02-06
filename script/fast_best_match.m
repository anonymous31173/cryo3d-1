% Script for running fast best match method using subspace approximations

% Created by Nicha C. Dvornek, 09/2014
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Configure parameters

addpath(fullfile(cd, '../src/best_match'));
db0 = fullfile(cd, '../samples/db-test');
addpath(db0);
pathout = [db0 '/'];

if (~isempty (gcp('nocreate')) ) % matlab 2014, may not be needed
    delete(gcp('nocreate'));
end
parpool;

% Stuff for timing
totaltime = tic;

% Set up - user parameters
configfile = 'fast_best_match_config.txt';
[imfile,imvar,imreconfile,imreconvar,initprojfile,maxmem,numthreads,...
    dispflag,substep,reconhalf,reconstartind,normprojint,numruns,...
    maxnumiter,rotstart,rotstep,rotend,transmax,transdelta,transwidth,...
    convtol,f,savemrc,alignims] = read_config_file(configfile);

% Reconstruction parameters
l_norm = 0.1;
l_smooth = -10;
iter_lim = 10;
stop_lim = 0.03;


%% Fast best match outer loop
for run = 1:numruns
    
    totaltime = tic;
    disp(' ');
    disp(['Run ' num2str(run)]);
    
    if run > 1
        reset(gpuDevice);
        writefile = [pathout savename '_reinit.mat'];  
        proj_init_from_file([pathout savename],initprojfile,writefile,0);
        initprojfile = writefile;        
    end
    
    % Load things
    if run == 1 
        disp('Loading images and setting up image subspace'); tic;
        
        % Check if pca of images already exists
        vars = whos('-file',imfile);
        if ~ismember('latentim',{vars.name})
            % Do PCA
            l = load(imfile,imvar);
            data = single(l.(imvar));
            clear l
            disp('PCA of images');
            data = reshape(data,[size(data,1)*size(data,2),size(data,3)])';  
            tic; [coeffim, scoreim, latentim] = pca(data); toc;
            clear data
            save(imfile,'-append','coeffim','scoreim','latentim');
        end

        % Determine subspace size of images
        if ~exist('latentim','var');
            load(imfile,'latentim');
        end
        latent_der = latentim(2:end) - latentim(1:end-1);
        latent_der2 = latent_der(2:end) - latent_der(1:end-1);
        latent_der2_avg = conv([1 1 1 ]./3,abs(latent_der2));
        numimcoeffs = find(abs(latent_der2_avg) < f,1) + 3;
        clear latentim;
        disp(['Number of image basis elements: ' num2str(numimcoeffs)]);
        
        % Set up image subspace and coeffs
        if ~exist('coeffim','var')
            load(imfile,'coeffim');
        end
        imbasis = coeffim(:,1:numimcoeffs-1); % Each col is numpixel-length basis elem
        clear coeffim
        if ~exist('scoreim','var')
            load(imfile,'scoreim');
        end
        imcoeffs = [ones(size(scoreim,1),1), scoreim(:,1:numimcoeffs-1)]; % Each row is set of coeffs for an image
        clear scoreim;
        
        % Load images/ctf indices and put in mean vector into subspace
        load(imfile,'ctfinds');
        l = load(imfile,imvar);
        noisyims = single(l.(imvar));
        meanim = mean(noisyims,3);
        imbasis = [meanim(:), imbasis];
        clear l meanim;
        
        %%%% FOR TESTING %%%%%%%%%%%%%%%%%%%%
        if substep > 0
            disp(['DIVIDING TOTAL DATA BY ' num2str(substep)]);
            noisyims = noisyims(:,:,1:substep:end);
            ctfinds = ctfinds(1:substep:end);
            imcoeffs = imcoeffs(1:substep:end,:);
        end

        % Reconstruct half?
        if reconhalf
            disp(['Reconstruct half ' num2str(reconstartind) ' of the data']);
            noisyims = noisyims(:,:,reconstartind:2:end);
            ctfinds = ctfinds(reconstartind:2:end);
            imcoeffs = imcoeffs(reconstartind:2:end,:);
        end

        toc;
    end
    
    disp('Loading initial structure and templates'); tic;
    if run > 1
        ps_1x = proj_struct;
        clear proj_struct
        load(initprojfile,'coeffproj','scoreproj','latentproj','maskim','mask','coord_axes','data_axes','ctfs','structure','proj_struct');
    else    
        % Check if all initial model parameters exist
        vars = whos('-file',initprojfile);
        if ~ismember('data_axes',{vars.name})
            % Get the initial model parameters
            initprojfile = make_init_model(configfile, pathout);
        end
        % Rescale projection intensities to match images
        if normprojint
            load(initprojfile,'maskim','mask','coord_axes','data_axes','ctfs','structure','proj_struct');
            disp('Rescaling projection intensities and initialize basis');
            proj_struct = rescale_proj_ints(proj_struct,noisyims);
            disp('pca');
            data = reshape(proj_struct,[size(proj_struct,1)*size(proj_struct,2),size(proj_struct,3)])';
            pcatic = tic; [coeffproj, scoreproj, latentproj] = princomp(data); toc(pcatic);
            clear data;
        else
            % no rescaling
            load(initprojfile,'coeffproj','scoreproj','latentproj','maskim','mask','coord_axes','data_axes','ctfs','structure','proj_struct');
        end
    end
    if (~exist('structmask','var'))
        structmask = ones(size(structure));
    end
    
    % Set up projection subspace and coeffs
    latent_der = latentproj(2:end) - latentproj(1:end-1);
    latent_der2 = latent_der(2:end) - latent_der(1:end-1);
    latent_der2_avg = conv([1 1 1 ]./3,abs(latent_der2));
    numprojcoeffs = find(abs(latent_der2_avg) < f,1) + 3;
    if (latentproj(numprojcoeffs-2) == 0)
        numprojcoeffs = find(latentproj == 0,1);
    end
    clear latentproj latent_der latent_der2 latent_der2_avg
    disp(['Number of template basis elements: ' num2str(numprojcoeffs)]);
    meanproj = mean(proj_struct,3);
    numproj = size(proj_struct,3);
    projbasis = [meanproj(:), coeffproj(:,1:numprojcoeffs-1)];
    clear coeffproj meanproj;
    projcoeffs = [ones(numproj,1), scoreproj(:,1:numprojcoeffs-1)];
    clear scoreproj;    
    
    % Initialize things
    disp('Initializing things'); tic;
    numim = size(imcoeffs,1);
    rots = rotstart:rotstep:rotend;
    numrot = length(rots);
    [x, y] = meshgrid(-transmax:transdelta:transmax,-transmax:transdelta:transmax);
    trans = [x(:), y(:)];
    clear x y
    numtrans = size(trans,1);
    if run == 1
        sigmastart = std(noisyims(:));
    end
    clear noisyims;   
    sigma1 = sigmastart;
    sigma2 = sigma1*100;
    sigmaconst = 0;
    sigmathresh1 = 0.05;
    sigmathresh2 = 0.05;
    maskimcol = maskim(:);
    numpix = size(imbasis,1);
    numpixsqrt = sqrt(numpix);
    nummaskpix = sum(maskim(:));
    numctf = max(ctfinds);
    iminds = (1:numim)';
    projnorms = zeros(numproj,1);
    onesprojcoeff = ones(numprojcoeffs,1,'int8');
    onesproj = ones(numproj,1,'int8');
    proj_est = reshape(projbasis*projcoeffs'.*maskimcol(:,onesproj),[numpixsqrt,numpixsqrt,numproj]);
    projbasis = projbasis .* maskimcol(:,onesprojcoeff);
    eps = 1e-20;
    
    % Start pool
    %if numthreads > 0 % matlab2013
    %   if matlabpool('size') > 0
    %        matlabpool close;
    %    end
    %    matlabpool('local',numthreads);
    %end
    
    % Set up initial search domains for translations
    disp('Set up translation search domains'); transtime = tic;
    searchtrans = get_trans_domains(1:numim,ceil(numtrans/2)*ones(numim,1),ones(numim,1),trans,floor(transmax/2),floor(transmax/2),numim);
    toc(transtime);
    
    % Compute image norms for translated mask
    if run == 1
        disp('Calc image norms'); calcnorm = tic;
        imnorms = comp_im_norms(imbasis,imcoeffs,maskim,trans,maxmem);
        toc(calcnorm);
    end
    
    %% Main loop
    % preallocate memory
    wallitertimes = zeros(1,maxnumiter);
    ssdtimes = zeros(1,maxnumiter);
    itertimes = zeros(1,maxnumiter);
    for n = 1:maxnumiter
        
        itertime = tic;
        disp(' ');
        disp(['*****Best Match iter ' num2str(n) '*****']);
        
        % Calculate projection norms squared
        disp('Calc template norms'); pause(0.05); ssdtime = tic; tic;
        temp = reshape(imrotate(proj_est,45,'bilinear','crop'), [numpix numproj]);
        projnorms = dot(temp,temp)';
        clear temp;
        toc;
        
        % Compute inner products
        disp('Calc inner products'); pause(0.05); tic;
        ips = comp_inner_prods(projbasis,imbasis,rots,numprojcoeffs,numrot,numimcoeffs,numpixsqrt,numpix,trans,searchtrans,numtrans);
        toc;
        
        % Calculate the SSDs to find best projection direction and
        % transformation params
        disp('Calc SSDs'); pause(0.05);tic;
        [projinds,rotinds,SSDs,transinds,scales] = comp_SSDs_fast_best_match(projnorms,projcoeffs,imcoeffs,ips,ctfinds,numim,numctf,numproj,numrot,searchtrans,imnorms,maxmem);
        toc;
        ssdtime = toc(ssdtime);
        ssdtimes(n) = ssdtime;
        notssdtime = tic;
        clear ips;
        
        % Assign last iteration values
        proj_last = proj_est;
        sigma1_2 = sigma1^2;
        sigma2_2 = sigma2^2;
        
        % Update noise variances
        disp('Update noise standard deviations'); tic;
        sigma1 = sqrt(1/nummaskpix/numim*(sum(SSDs(:)))) + sigmaconst;
        if sigma1 < sigmathresh1
            sigma1 = sigmathresh1 + sigmaconst;
        end
        if n > 1
            sigma2 = sqrt(1/nummaskpix/numproj*sum(sum(sum((proj_struct - proj_est).^2)))) + sigmaconst;
            if sigma2 < sigmathresh2
                sigma2 = sigmathresh2 + sigmaconst;
            end
        end
        disp(['sigma1 = ' num2str(sigma1)]);
        disp(['sigma2 = ' num2str(sigma2)]);
        toc;
        
        % Get number of images aligned to each template
        disp('Get number of images aligned to each template'); tic;
        scaleperproj = zeros(numproj,1);
        for j = 1:numproj
            inds = find(projinds == j);
            scaleperproj(j) = sum(scales(inds).^2);
        end
        toc;
        
        % Calculate sum of images aligned to each template
        disp('Calc sum of aligned images for each template'); pause(0.05); tic;
        sumalignedim = avg_rot_ims(imbasis,imcoeffs,projinds,rotinds,iminds,scales,rots,numpix,numim,numproj,numrot,numimcoeffs,numpixsqrt,trans,transinds);
        toc;
        
        % Update template matrix
        disp('Update template matrix'); pause(0.05); tic;
        projbasis = double((sigma2_2*sumalignedim+sigma1_2*reshape(proj_struct,[numpix,numproj]))*...
            (projcoeffs / (sigma2_2*projcoeffs'*(scaleperproj(:,onesprojcoeff).*projcoeffs)+sigma1_2*(projcoeffs'*projcoeffs) ) ));
        toc;
        
        % Update template coefficients
        disp('Update template coeffs'); pause(0.05); tic;
        projcoeffs = double( ( (projbasis'*projbasis)\(projbasis'*(sigma2_2*sumalignedim + sigma1_2*reshape(proj_struct,[numpix,numproj])))./...
            (sigma2_2*scaleperproj(:,onesprojcoeff)' + sigma1_2))' );
        clear sumalignedim proj_struct;
        
        % Update structure
        disp('Update templates and structure'); pause(0.05); tic;
        proj_est = reshape(projbasis*projcoeffs',[numpixsqrt,numpixsqrt,numproj]);
        fproj_est = zeros(size(proj_est));
        for j = 1:numproj
            fproj_est(:,:,j) = fftshift(fft2(proj_est(:,:,j)));
        end
        if n > 1
            structure = reconstruct_by_cg_w_ctf_par(fproj_est,data_axes,ctfs,mask,l_norm,l_smooth,iter_lim,stop_lim,structure);
        else
            structure = reconstruct_by_cg_w_ctf_par(fproj_est,data_axes,ctfs,mask,l_norm,l_smooth,iter_lim,stop_lim);
        end
        structure = structure.*structmask;
        clear fproj_est
        toc;
        
        % Update projections of structure
        disp('Update structure projections'); pause(0.05); tic;
        fproj_struct = project_in_all_directions_w_ctf_par(structure,mask,coord_axes,ctfs);
        proj_struct = zeros(size(proj_est));
        for j = 1:numproj
            proj_struct(:,:,j) = real(ifft2(ifftshift(fproj_struct(:,:,j)))).*maskim;
        end
        clear fproj_struct
        toc;
        
        % Masking for next round
        proj_est = proj_est .* maskim(:,:,onesproj);
        projbasis = projbasis .* maskimcol(:,onesprojcoeff);
        
        % Update translation search
        if numtrans > 1
            disp('Update translation search domain'); tic;
            searchtrans = get_trans_domains(iminds,transinds,ones(numim,1),trans,transwidth,transdelta,numim);
            toc;
        end
        
        % Check convergence
        disp('Check convergence'); tic;
        [done,err,pind] = check_convergence(proj_last,proj_est,convtol,numproj);
        if pind > 0
            disp(['Error: ' num2str(err) ' for proj ' num2str(pind)]);
        else
            disp('Converged!');
        end
        toc;
        
        % Timing stuff
        itertime = toc(itertime);
        wallitertimes(n) = itertime;
        disp(['Iteration time: ' num2str(itertime) ' seconds']);
        notssdtime = toc(notssdtime);
        itertimes(n) = ssdtime + notssdtime;
        disp(['Serial Iteration time: ' num2str(itertimes(n)) ' seconds']);
        
        if mod(n-1,1) == 0
            savename = ['run_' num2str(run) '_iter_' num2str(n)];
            save([pathout savename],'-v7.3','structure','projbasis','projcoeffs','projinds','rotinds','transinds','scales','searchtrans','err');
        end
        if done == 1
            break;
        end

    end
    
    % Calculate reconstruction using final alignment params and original noisy images
    disp(' '); disp('Calc final estimate!'); disp('Update final projection templates'); tic;
    proj_last = proj_est;
    l = load(imreconfile,imreconvar);
    noisyims = single(l.(imreconvar));
    clear l
    
    %%%% FOR TESTING %%%%%%%%%%%%%%%%%%%%
    if substep > 0
        disp(['DIVIDING TOTAL DATA BY ' num2str(substep)]);
        noisyims = noisyims(:,:,1:substep:end);
        numim = size(noisyims,3);
    end
    
    if reconhalf
        noisyims = noisyims(:,:,reconstartind:2:end);
        numim = size(noisyims,3);
    end
    
    % Update projection templates using original images
    noisyims_g = gpuArray(noisyims);
    clear noisyims
    disp('Calc image weights'); tic;
    weights = zeros(numim,1);
    for j = 1:numproj
        inds = find(projinds == j);
        if (~isempty(inds))
            weights(inds) = scales(inds) ./ sum(scales(inds).^2);
        end
    end
    proj_est = update_templates2(noisyims_g,iminds,projinds,rotinds,transinds,weights,rots,trans,numpixsqrt,numim,numproj);
    
    % Calculate final reconstruction with original images
    disp('Final reconstruction'); tic;
    fproj_est = zeros(size(proj_est));
    for j = 1:numproj
        fproj_est(:,:,j) = fftshift(fft2(proj_est(:,:,j)));
    end
    takeoutinds = [];
    zeroim = zeros(numpixsqrt,numpixsqrt);
    % Take out directions that have no images to speed up reconstruction
    for j = 1:numproj
        if isequal(fproj_est(:,:,j),zeroim)
            takeoutinds = [takeoutinds; j];
        end
    end
    keepinds = 1:numproj;
    keepinds(takeoutinds) = [];
    structure_final = reconstruct_by_cg_w_ctf_par(fproj_est(:,:,keepinds),data_axes(:,keepinds),ctfs(:,:,mod(keepinds-1,numctf)+1),mask,l_norm,l_smooth,iter_lim,stop_lim);
    toc;
        
    % Display stats summary
    totaltime = toc(totaltime);
    disp(['Average time per serial iteration: ' num2str(mean(itertimes)) ' seconds']);
    disp(['Average time per serial SSD calc: ' num2str(mean(ssdtimes)) ' seconds']);
    disp(['Average wall time per iteration: ' num2str(mean(wallitertimes)) ' seconds']);
    disp(['Total wall time: ' num2str(totaltime) ' seconds']);
    
    % Save
    if strcmp(imfile(end-3:end),'.mat')
        savename = imfile(1:end-4);
    else
        savename = imfile;
    end
    savename = [savename '_fastbm_' num2str(numimcoeffs) '_' num2str(numprojcoeffs) '_' num2str(rotstep) 'd_' num2str(transmax) num2str(transdelta) num2str(transwidth) 't_' num2str(run) 'x'];
    if substep > 0
        savename = [savename '_sub' num2str(substep)];
    end
    if reconhalf
        savename = [savename '_h' num2str(reconstartind)];
    end
    save([pathout savename],'-v7.3','structure_final','structure','proj_struct','proj_est','weights','projinds','rotinds','rots','SSDs','totaltime','wallitertimes','itertimes','ssdtimes','n','sigma1','sigma2','projbasis','projcoeffs','searchtrans','transinds','trans','scales','numprojcoeffs','numimcoeffs','f','imfile','initprojfile','imreconfile','convtol','coord_axes');
    
    % Some clean up
    clear structure_final structure proj_est proj_last
    
end

% Recon with largest mask possible for FSC calculations
disp('Reconstruct one more time with largest mask possible');
mask = get_mask_struct_ncd([numpixsqrt numpixsqrt numpixsqrt],1); % reconstruct with largest mask possible
recon = reconstruct_by_cg_w_ctf_par(fproj_est(:,:,keepinds),data_axes(:,keepinds),ctfs(:,:,mod(keepinds-1,numctf)+1),mask,l_norm,l_smooth,iter_lim,stop_lim);
%matlabpool close
delete(gcp('nocreate'));
save([pathout savename],'-append','recon');
if savemrc
    writeMRC(recon,savemrc,[pathout 'fbm_recon.mrc'])
end

% Align images and save
if alignims
    disp('Aligning images to best-matched projection and saving');
    l = load(imreconfile,imreconvar);
    noisyims = single(l.(imreconvar));
    clear l
    aligned_ims = align_images(noisyims,rotinds,transinds,rots,trans);
    save([pathout savename],'-append','aligned_ims');
end