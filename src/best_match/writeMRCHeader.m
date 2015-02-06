function handle = writeMRCHeader(map,pixA,filename,nim,org)% function handle=WriteMRCHeader(map,pixA,filename,nim,org)% Write out the header of an MRC map file, and leave the file open,% returning the file handle, so that data can be written sequentially into% the file and then the file closed.  Data are written in little-endian style,% as float32 values.% If you want to write more slices than are contained in map, give the% total number of slices (or 2d images) in the optional nim argument.  The% optional argument org is the starting point of the volume, an integer in% units of voxels.  Default would be [0 0 0], but another possibility would% be [c c c] where c=-floor(n/2).%% Example: write out 10,000 random images.%     images=randn(64,64,1000);%     f=WriteMRCHeader(images,2.8,'test.mrc',10000);%     fwrite(f,images,'float32');%     for i=2:10%         images=randn(64,64,1000);%         fwrite(f,images,'float32');%     end;%     fclose(f);% % Changed Jul2011 to support the origin argument.  fs% Files are always written in little-ended format.% Figure out if we have a little-ended machine.q=typecast(int32(1),'uint8');machineLE=(q(1)==1);  % true for little-endian machinehdr=int32(zeros(256,1));sizes=size(map);if numel(sizes)<3    sizes(3)=1;end;if nargin<5    org=-floor(sizes/2);  % Default origin is such that else    org=org(:);end;if nargin >3    sizes(3)=nim;end;% Get statisticsmap=reshape(map,numel(map),1);  % convert it into a 1D vectortheMean=mean(map);theSD=std(map);theMax=max(map);theMin=min(map);% Number of voxels in the map or submaphdr(1:3)=sizes; % number of columns, rows, sectionshdr(4)=2;  % mode: real, float valueshdr(5:7)=org;  % origin of the map% Number of voxels in the full unit cellhdr(8:10)=hdr(1:3);  % number of intervals along x,y,z% Unit cell sizes and angleshdr(11:13)=typecast(single(single(hdr(8:10))*pixA),'int32');  % Cell dimensionshdr(14:16)=typecast(single([90 90 90]),'int32');   % Angleshdr(17:19)=(1:3)';  % Axis assignmentshdr(20:22)=typecast(single([theMin theMax theMean]'),'int32');hdr(23)=0;  % Space group 0 (default)if machineLE    hdr(53)=typecast(uint8('MAP '),'int32');    hdr(54)=typecast(uint8([68 65 0 0]),'int32');  % LE machine stamp.else    hdr(53)=typecast(uint8(' PAM'),'int32');  % LE machine stamp, for writing with BE machine.    hdr(54)=typecast(uint8([0 0 65 68]),'int32');endhdr(55)=typecast(single(theSD),'int32');handle=fopen(filename,'w','ieee-le');  % Here we force little-ended order.if handle<0    error(['File could not be opened for writing: ' filename]);end;count1=fwrite(handle,hdr,'int32');