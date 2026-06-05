classdef ECGManualUI < handle
    properties
        inspector
    end

    methods
        function obj = ECGManualUI(inspector)
            if nargin < 1
                inspector = [];
            end
            obj.inspector = inspector;
        end

function addPeak(obj, direction)
%
% function addPeak(direction)
%
% direction: -1 add peak to left of selected peak; 1 add to right

global EKG;

selected_peak = obj.getSingleSelectedEcgPeakIdx(true);
if isempty(selected_peak)
    return
end

axes(findobj('Tag', 'AxesEkgPlot'));

% EKG.indxPeaks contains the indices of the plotted peaks so selected peak is really EKG.indxPeaks(selected_peak)
%selected_peak = EKG.indxPeaks(selected_peak);
numPeaks = length(EKG.t_peaks);
%disp(['Selected peak(s): ' mat2str(selected_peak)]);

% add peak half way between selected peak and one before or after
if direction < 0  % add to left
    if selected_peak > 1
        previous_peak_time = EKG.t_peaks(selected_peak-1);
        add_peak_time = (EKG.t_peaks(selected_peak)+previous_peak_time)/2;
        add_peak_sample = round(add_peak_time*EKG.sampRate);
        add_peak_amplitude = (EKG.peaks(selected_peak,2)+EKG.peaks(selected_peak-1,2))/2;
        add_peak_indx = selected_peak;
    else % selected_peak = 1; use half the interval between peaks 1 and 2
        dif_peak_time = EKG.t_peaks(2)-EKG.t_peaks(1);
        add_peak_time = max((EKG.t_peaks(1)-dif_peak_time/2),0);
        add_peak_sample = round(add_peak_time*EKG.sampRate);
        add_peak_amplitude = (EKG.peaks(1,2)+EKG.peaks(2,2))/2; %mean of peaks 1 and 2
        add_peak_indx = selected_peak;
    end
%    % make a slot for the new peak pointer
%    for iPeak = numPeaks:-1:selected_peak
%        EKGplotParams.hpeak(iPeak+1) = EKGplotParams.hpeak(iPeak);
%	end
        
else % direction > 0 add to right
    if selected_peak < numPeaks
        next_peak_time = EKG.t_peaks(selected_peak+1);
        add_peak_time = (EKG.t_peaks(selected_peak)+next_peak_time)/2;
        add_peak_sample = round(add_peak_time*EKG.sampRate);
        add_peak_amplitude = (EKG.peaks(selected_peak,2)+EKG.peaks(selected_peak+1,2))/2;
        add_peak_indx = selected_peak + 1;
    else % selected_peak = numPeaks; use half the interval between last two peaks 
        dif_peak_time = EKG.t_peaks(numPeaks)-EKG.t_peaks(numPeaks-1);
        add_peak_time = min((EKG.t_peaks(numPeaks)+dif_peak_time/2),EKG.plot.maxTime);
        add_peak_sample = round(add_peak_time*EKG.sampRate);
        add_peak_amplitude = (EKG.peaks(numPeaks,2)+EKG.peaks(numPeaks-1,2))/2; %mean of last two peaks
        add_peak_indx = selected_peak + 1;
    end
%    % make a slot for the new peak pointer
%    for iPeak = numPeaks:-1:selected_peak+1
%        EKGplotParams.hpeak(iPeak+1) = EKGplotParams.hpeak(iPeak);
%	end
end
%disp(['Add peak index: ' num2str(add_peak_indx)]);
if obj.hasInspector()
    if direction < 0
        note = "ui_add_left";
    else
        note = "ui_add_right";
    end
    obj.inspector.insertPeak(add_peak_sample, note);
    return
end

% update peaks and ibis and add new peak to EKG plot
tmp = zeros(numPeaks+1,2);
old_peaks = setxor(add_peak_indx,[1:numPeaks+1]);
tmp(old_peaks,:) = EKG.peaks;
tmp(add_peak_indx,:) = [add_peak_sample add_peak_amplitude];
EKG.peaks = tmp;
clear tmp;
EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;
%update indxPeaks
EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime); 
EKG.ibis = 1000*diff(EKG.t_peaks); %ibi in milliseconds
y = EKG.ibis;   %leave in ms
x=EKG.t_peaks(2:end);
t=(x-x(1)); %x in seconds; second beat at t=0
tMax = round(t(end));
xx=0:0.1:tMax;        % ibi interpolated to 10 Hz
yy = spline(t,y,xx);
EKG.ibi_spline = yy;
EKG.ibi_spline_t = xx+x(1);

% remove 'o's if present
h = findobj(gca,'Type','text','-regexp','Tag','^peak[0-9]+$');
if ~isempty(h)
    delete(h);        
end

% replot peaks with new one added
for i = 1:length(EKG.indxPeaks)
	iPeak = EKG.indxPeaks(i);
%	    disp(num2str(iPeak));
	EKG.hpeaks(iPeak) = text(EKG.t_peaks(iPeak),EKG.peaks(iPeak,2),'o', ...
		'color',[1 1 0],'userdata',[1 0 0], ...
		'HorizontalAlignment','center','VerticalAlignment','middle', ...
		'Tag',['peak' num2str(iPeak)], ...
		'buttondownfcn', ...
			['tmpstr = get(gco, ''userdata'');' ...
			 'set(gco, ''userdata'', get(gco, ''color''));' ...
			 'set(gco, ''color'', tmpstr); clear tmpstr;'] );
end
obj.drawIbiPlot();
obj.drawPsdPlot();
end

function changeEkgScale(obj, x)
%
%
%

global EKG;

if x < 0 
    EKG.plot.widthTime = round(EKG.plot.widthTime/2); 
else
    EKG.plot.widthTime = min(EKG.plot.widthTime*2,EKG.plot.maxTime); 
end
EKG.plot.incrLR = (EKG.plot.endTime-EKG.plot.startTime);  % 1% of plot width
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function deletePeak(obj)
%
% function deletePeak
%

global EKG;

selected_peak = obj.getSelectedEcgPeakIdx(true);
if isempty(selected_peak)
    return
end

axes(findobj('Tag', 'AxesEkgPlot'));

if obj.hasInspector()
    sampleIdx = EKG.peaks(selected_peak, 1);
    obj.clearEcgPeakSelection();
    obj.inspector.deletePeaks(sampleIdx, "ui_delete");
    return
end

% update peaks and ibis and remove selected peak from EKG plot
EKG.peaks(selected_peak,:) = [];


EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;
if numel(EKG.t_peaks) < 2
    EKG.ibis = [];
    EKG.ibi_spline = [];
    EKG.ibi_spline_t = [];
    EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime);
    obj.drawIbiPlot();
    obj.drawEkgPlot();
    obj.drawPsdPlot();
    return
end
EKG.ibis = 1000*diff(EKG.t_peaks); %ibi in milliseconds
y = EKG.ibis;   %leave in ms
x=EKG.t_peaks(2:end);
t=(x-x(1)); %x in seconds; second beat at t=0
tMax = round(t(end));
xx=0:0.1:tMax;        % ibi interpolated to 10 Hz
yy = spline(t,y,xx);
EKG.ibi_spline = yy;
EKG.ibi_spline_t = xx+x(1);

%update indxPeaks
EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime); 

% remove 'o's if present
h = findobj(gca,'Type','text','-regexp','Tag','^peak[0-9]+$');
if ~isempty(h)
    delete(h);        
end

% replot peaks without deleted one
for i = 1:length(EKG.indxPeaks)
	iPeak = EKG.indxPeaks(i);
%	    disp(num2str(iPeak));
	EKG.hpeaks(iPeak) = text(EKG.t_peaks(iPeak),EKG.peaks(iPeak,2),'o', ...
		'color',[1 1 0],'userdata',[1 0 0], ...
		'HorizontalAlignment','center','VerticalAlignment','middle', ...
		'Tag',['peak' num2str(iPeak)], ...
		'buttondownfcn', ...
			['tmpstr = get(gco, ''userdata'');' ...
			 'set(gco, ''userdata'', get(gco, ''color''));' ...
			 'set(gco, ''color'', tmpstr); clear tmpstr;'] );
end


obj.drawIbiPlot();
obj.drawPsdPlot();
end

function drawEkgPlot(obj)
%
% function drawEkgPlot
%
% must be called after initEkgPlot
% update: 0 = no first call to drawEkgPlot; 1 = just update plot with new time range 

global EKG;

EKG.plot.endTime = EKG.plot.startTime + EKG.plot.widthTime;
startSamp = floor(EKG.plot.startTime*EKG.sampRate) + 1;
startSamp = min(max(startSamp, 1), length(EKG.signal));
endSamp = min(floor(EKG.plot.endTime*EKG.sampRate),length(EKG.signal));
if endSamp < startSamp
    endSamp = startSamp;
end
%disp([num2str(startSamp)  ' endSamp: ' num2str(endSamp)]);
visibleSignal = EKG.signal(startSamp:endSamp);
yCandidates = visibleSignal(:);
if ~isempty(EKG.peaks)
    visiblePeakIdx = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime);
    if ~isempty(visiblePeakIdx)
        yCandidates = [yCandidates; EKG.peaks(visiblePeakIdx,2)];
    end
end
yCandidates = yCandidates(isfinite(yCandidates));
if isempty(yCandidates)
    yCandidates = 0;
end
yMin = min(yCandidates);
yMax = max(yCandidates);
yRange = yMax - yMin;
if ~isfinite(yRange) || yRange <= 0
    yRange = max(abs(yMax), 1);
end
padding = 0.1 * yRange;
EKG.ekgMin = yMin - padding;
EKG.ekgMax = yMax + padding;
EKG.plot.incrUpDn = 0.05 * max(EKG.ekgMax - EKG.ekgMin, eps);

axes(findobj('Tag', 'AxesEkgPlot'));


% remove line if present

delete(findobj('Tag', 'LineEkgData'))
delete(findobj('Tag', 'LineEkgDataThreshold'))

set(findobj('Tag', 'AxesEkgPlot'), 'XLim', [floor(EKG.plot.startTime) ceil(EKG.plot.endTime)]);
set(findobj('Tag', 'AxesEkgPlot'), 'YLim', [EKG.ekgMin EKG.ekgMax]);

%set(get(findobj('Tag', 'AxesEkgPlot'), 'Title'), 'String', EKG.inFile, 'Interpreter', 'none' );
set(findobj('Tag', 'FigureEkgPlot'), 'Name', EKG.inFile); %add the file address on the figure name instead of the axes title

cf = gcf;
t = linspace(EKG.plot.startTime,min(EKG.plot.endTime,EKG.plot.maxTime),length(visibleSignal));
line(t,visibleSignal,'Tag', 'LineEkgData','color','blue');

% draw peaks if there are any
if ~isempty(EKG.peaks)
	% find selected peak if there is one
	selected_peak = obj.getSelectedEcgPeakIdx(false);

	% remove 'o's if present
	h = findobj(gca,'Type','text','-regexp','Tag','^peak[0-9]+$');
	if ~isempty(h)
		delete(h);        
    end    
    
    
    EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime); 
    for i = 1:length(EKG.indxPeaks)
        iPeak = EKG.indxPeaks(i);
%	    disp(num2str(iPeak));
		if ismember(iPeak, selected_peak)
			EKG.hpeaks(iPeak) = text(EKG.t_peaks(iPeak),EKG.peaks(iPeak,2),'o', ...
				'color',[1 0 0],'userdata',[1 1 0], ...
				'HorizontalAlignment','center','VerticalAlignment','middle', ...
				'Tag',['peak' num2str(iPeak)], ...
				'buttondownfcn', ...
					['tmpstr = get(gco, ''userdata'');' ...
					 'set(gco, ''userdata'', get(gco, ''color''));' ...
					 'set(gco, ''color'', tmpstr); clear tmpstr;'] );
	    else
			EKG.hpeaks(iPeak) = text(EKG.t_peaks(iPeak),EKG.peaks(iPeak,2),'o', ...
				'color',[1 1 0],'userdata',[1 0 0], ...
				'HorizontalAlignment','center','VerticalAlignment','middle', ...
				'Tag',['peak' num2str(iPeak)], ...
				'buttondownfcn', ...
					['tmpstr = get(gco, ''userdata'');' ...
					 'set(gco, ''userdata'', get(gco, ''color''));' ...
					 'set(gco, ''color'', tmpstr); clear tmpstr;'] );
		end
    end
    % now plot threshold line
    xThreshold = [EKG.plot.startTime EKG.plot.endTime];
    yThreshold = [EKG.threshold EKG.threshold];
    line(xThreshold,yThreshold,'color','cyan','Tag', 'LineEkgDataThreshold');

else
    h = findobj(gca,'Type','text','-regexp','Tag','^peak[0-9]+$');
    if ~isempty(h)
        delete(h);
    end
    EKG.indxPeaks = [];
end
%----------------------------------------darwRspPlot----------------------%

if ~isempty(EKG.RSP.signal)
  
 EKG.rspMin = min(EKG.RSP.signal(startSamp:endSamp));
if EKG.rspMin >= 0
    EKG.rspMin = floor(0.9*EKG.rspMin);
else
    EKG.rspMin = floor(1.1*EKG.rspMin);
end
EKG.rspMax = ceil(1.1*max(EKG.RSP.signal));

axes(findobj('Tag', 'AxesRspPlot'));

% remove line if present
delete(findobj('Tag', 'LineRspData'))

set(findobj('Tag', 'AxesRspPlot'), 'XLim', [floor(EKG.plot.startTime) ceil(EKG.plot.endTime)]);
set(findobj('Tag', 'AxesRspPlot'), 'YLim', [EKG.rspMin EKG.rspMax]);

cf = gcf;
axes2 = findobj('Tag', 'AxesRspPlot');
t = linspace(EKG.plot.startTime,min(EKG.plot.endTime,EKG.plot.maxTime),length(EKG.RSP.signal(startSamp:endSamp)));
line(t,EKG.RSP.signal(startSamp:endSamp),'Tag', 'LineRspData','color','red', 'Parent',axes2);    
axes(findobj('Tag', 'AxesEkgPlot'));
end;
%-------------------------------------------------------------%
end

function drawIbiPlot(obj)
%
% function drawIbiPlot
%

global EKG;

selected_ibi = obj.getSelectedIbiPeakIdx(false);
if numel(selected_ibi) > 1
    selected_ibi = selected_ibi(1);
end

[visibleIdx, t_visible, ibis_all, validIbiMask, ibi_spline_t, ibi_spline] = obj.getVisibleIbiSeries();
if isempty(ibis_all)
    return
end

EKG.plot.endTime = EKG.plot.startTime + EKG.plot.widthTime;
windowTimes = t_visible(2:end);
inWindowMask = windowTimes >= EKG.plot.startTime & windowTimes <= EKG.plot.endTime;
invalidInWindow = ~validIbiMask & inWindowMask;
if any(validIbiMask & inWindowMask)
    ibisRange = ibis_all(validIbiMask & inWindowMask);
elseif any(inWindowMask)
    ibisRange = ibis_all(inWindowMask);
elseif any(validIbiMask)
    ibisRange = ibis_all(validIbiMask);
else
    ibisRange = ibis_all;
end
ibisRange = ibisRange(:);
if any(invalidInWindow)
    ibisRange = [ibisRange; ibis_all(invalidInWindow)];
end
if isempty(ibisRange) || ~any(isfinite(ibisRange))
    return
end
ibiMin = floor(0.9*min(ibisRange));
ibiMax = ceil(1.1*max(ibisRange));
axes(findobj('Tag', 'AxesIbiPlot'));

% remove 'o's if present
h = findobj(gca,'Type','text','-regexp','Tag','^ibi');
if ~isempty(h),delete(h),end
% remove line if present
delete(findobj('Tag', 'LineIbiData'))

set(findobj('Tag', 'AxesIbiPlot'), 'XLim', [floor(EKG.plot.startTime) ceil(EKG.plot.endTime)]);
set(findobj('Tag', 'AxesIbiPlot'), 'YLim', [ibiMin ibiMax]);

spline_t_samps = find(ibi_spline_t >= EKG.plot.startTime & ibi_spline_t <= EKG.plot.endTime);
startSamp = floor(EKG.plot.startTime*10) + 1; 
endSamp = min(floor(EKG.plot.endTime*10),length(ibi_spline)); 
%t_plot = linspace(EKG.plot.startTime,EKG.plot.endTime,endSamp-startSamp+1);
if ~isempty(ibi_spline_t) && ~isempty(ibi_spline)
    line(ibi_spline_t(spline_t_samps),ibi_spline(spline_t_samps),'Tag', 'LineIbiData','color','blue');
end
% find peaks in plot time range
indxPeaks = visibleIdx(t_visible >= EKG.plot.startTime & t_visible <= EKG.plot.endTime);
indxPeaks = indxPeaks(:).';
for k = 1:numel(indxPeaks)
    iIBI = indxPeaks(k);
    pos = find(visibleIdx == iIBI, 1, 'first');
    if isempty(pos) || pos <= 1
        continue
    end
    if validIbiMask(pos-1)
        if ~isempty(selected_ibi) && iIBI == selected_ibi
            pointColor = [1 0 0];
            pointUserdata = [1 1 0];
        else
            pointColor = [1 1 0];
            pointUserdata = [1 0 0];
        end
        h = text(t_visible(pos),ibis_all(pos-1),'o', ...
            'color',pointColor,'userdata',pointUserdata, ...
            'HorizontalAlignment','center','VerticalAlignment','middle', ...
            'Tag',sprintf('ibi%d', iIBI), ...
            'HitTest','on', ...
            'PickableParts','visible', ...
            'buttondownfcn', ...
                ['tmpstr = get(gco, ''userdata'');' ...
                 'set(gco, ''userdata'', get(gco, ''color''));' ...
                 'set(gco, ''color'', tmpstr); clear tmpstr;'] );
    else
        h = text(t_visible(pos),ibis_all(pos-1),'x', ...
            'color',[0.5 0.5 0.5],'userdata',[0.5 0.5 0.5], ...
            'HorizontalAlignment','center','VerticalAlignment','middle', ...
            'Tag',sprintf('ibiInvalid%d', iIBI), ...
            'HitTest','off', ...
            'PickableParts','none');
    end
end
end

function drawPsdPlot(obj)
%
% function drawPsdPlot
%
% must be called after initPsdPlot

global EKG;

[~, ~, ibis_all, validIbiMask, ~, ibi_spline] = obj.getVisibleIbiSeries();
if isempty(ibis_all) || ~any(validIbiMask)
    return
end
ibis_visible = ibis_all(validIbiMask);
if isempty(ibi_spline)
    return
end
yy = ibi_spline; %ibi spline interpolated to 10 samples/sec
yym = detrend(yy);   % detrend
yym = yym - mean(yym); % demean
nsamps = length(yym);
[pyy,f] = pwelch(yym,nsamps,0,nsamps,10); %all samples Hamming
axes(findobj('Tag', 'AxesPsdPlot'));

% delete line if already present
h = findobj(gca,'Type','line');
if ~isempty(h),delete(h),end

% delete text if already present
h = findobj(gca,'Type','text');
if ~isempty(h),delete(h),end

indx = find(f<=0.5);  %freqs up to 0.5 Hz
line(f(indx),pyy(indx));
maxY = max(pyy(indx));
set(findobj('Tag', 'AxesPsdPlot'), 'XLim', [0 0.5],'ylim',[0 ceil(1.5*maxY)]);
% 30-July-2007 added ability to change HF lower and upper bounds
% draw LF lower boundary at 0.04 Hz
% draw HF lower and upper bounds at HF_lower and HF_upper
line([0.04 0.04],[0.00 1e8],'color',[1 1 0]);  %
line([EKG.HF_lower EKG.HF_lower],[0.00 1e8],'color',[1 1 0]);
HF_lower_text = ['HF_L = ' sprintf('%4.2f',EKG.HF_lower)];
text(EKG.HF_lower,1.2*maxY,HF_lower_text);
line([EKG.HF_upper EKG.HF_upper],[0.00 1e8],'color',[1 1 0]);
HF_upper_text = ['HF_U = ' sprintf('%4.2f',EKG.HF_upper)];
text(EKG.HF_upper,maxY,HF_upper_text);
%compute RSA and put it in handles.rsa edit box
%integrate power between EKG.HF_lower and EKG.HF_upper Hz
indx = find(f>=0.04 & f<=EKG.HF_lower);
meanP = mean(pyy(indx));
lf = log(meanP*(EKG.HF_lower-0.04));
lfstr = sprintf('%6.3f',lf);
indx = find(f>=EKG.HF_lower & f<=EKG.HF_upper);
meanP = mean(pyy(indx));
hf = log(meanP*(EKG.HF_upper-EKG.HF_lower));
hfstr = sprintf('%6.3f',hf);
lfhfstr = sprintf('%6.3f',lf/hf);
% HR = number of beats / (time for beats in ms/(60000ms/minute))  i.e. beats per minute
% HR = number of beats x one minute/(time for beats to occur)
HR = length(ibis_visible)*60000/sum(ibis_visible);
hrstr = sprintf('%6.2f',HR);

set(findobj('Tag', 'LfEditBox'), 'String', lfstr);
set(findobj('Tag', 'HfEditBox'), 'String', hfstr);
set(findobj('Tag', 'LfHfEditBox'), 'String', lfhfstr);
set(findobj('Tag', 'HrEditBox'), 'String', hrstr);

%---------------------------------RSP PSD---------------------

if ~isempty(EKG.RSP.signal)
    
ys = EKG.RSP.signal(floor(EKG.RSPpointDown*EKG.sampRate)+1:ceil(EKG.RSPpointUp*EKG.sampRate)); %data of interest between upper and lower bounds
ysm = detrend(ys);   % detrend
ysm = ysm - mean(ysm); % demean
nsamps = length(ysm);
[psy,f] = pwelch(ysm,nsamps,0,nsamps,EKG.sampRate); %all samples Hamming
axes(findobj('Tag', 'AxesRSPPsdPlot'));

% delete line if already present
h = findobj(gca,'Type','line');
if ~isempty(h),delete(h),end

% % delete text if already present
% h = findobj(gca,'Type','text');
% if ~isempty(h),delete(h),end

indx = find(f<=0.5);  %freqs up to 0.5 Hz
line(f(indx),psy(indx), 'color', [1 0 0]);
end
end

function drawRspPlot(~)

%
% function drawRspPlot
%
% must be called after Resp

global EKG;

startSamp = floor(EKG.plot.startTime*EKG.sampRate) + 1; 
endSamp = min(floor(EKG.plot.endTime*EKG.sampRate),length(EKG.signal)); 

rspMin = min(EKG.RSP.signal(startSamp:endSamp));
if rspMin >= 0
    rspMin = floor(0.9*rspMin);
else
    rspMin = floor(1.1*rspMin);
end
rspMax = ceil(1.1*max(EKG.RSP.signal));

axes(findobj('Tag', 'AxesRspPlot'));

% remove line if present
delete(findobj('Tag', 'LineRspData'))

set(findobj('Tag', 'AxesRspPlot'), 'XLim', [floor(EKG.plot.startTime) ceil(EKG.plot.endTime)]);
set(findobj('Tag', 'AxesRspPlot'), 'YLim', [rspMin rspMax]);

set(get(findobj('Tag', 'AxesRspPlot'), 'Title'), 'String', EKG.RSP.inFile, 'Interpreter', 'none' )
cf = gcf;
axes2 = findobj('Tag', 'AxesRspPlot');
t = linspace(EKG.plot.startTime,min(EKG.plot.endTime,EKG.plot.maxTime),length(EKG.RSP.signal(startSamp:endSamp)));
line(t,EKG.RSP.signal(startSamp:endSamp),'Tag', 'LineRspData','color','red', 'Parent',axes2);
end

function exitHrv(~)
delete(findobj('Tag', 'FigureEkgPlot'))
delete(findobj('Tag', 'FigureEkgControl'))
delete(findobj('Tag', 'FigureIbiPlot'))
delete(findobj('Tag', 'FigurePsdPlot'))
end

function exitWithoutSaving(obj)
if obj.hasInspector()
    obj.inspector.cancelReview();
end
obj.exitHrv();
end

function undoReview(obj)
if obj.hasInspector()
    obj.inspector.undo();
end
end

function startOverReview(obj)
if obj.hasInspector()
    obj.inspector.startOver();
end
end

function clearEcgPeakSelection(~)
hAx = findobj('Tag', 'AxesEkgPlot');
if isempty(hAx) || ~ishandle(hAx)
    return
end
h = findobj(hAx,'Type','text','-regexp','Tag','^peak[0-9]+$');
for iPeak = 1:numel(h)
    set(h(iPeak), 'color', [1 1 0], 'userdata', [1 0 0]);
end
end

function findPeaks(obj)
%
% function findPeaks
%
% 27-July-2007 added computation of third argument (minSampsBetweenPeaks) for peakfinder
% 400 was a good value for a sample rate of 1000 
global EKG;

minSampsBetweenPeaks = 400*EKG.sampRate/1000;

signalFinite = EKG.signal(isfinite(EKG.signal));
thresholdCandidates = EKG.threshold;
if ~isempty(signalFinite)
    signalStd = std(signalFinite);
    thresholdCandidates = [thresholdCandidates signalStd 0.75*signalStd 0.5*signalStd 0.25*signalStd];
end
thresholdCandidates = thresholdCandidates(isfinite(thresholdCandidates));
thresholdCandidates = unique(thresholdCandidates, 'stable');

detectedPeaks = [];
selectedThreshold = [];
for iThreshold = 1:numel(thresholdCandidates)
    try
        candidatePeaks = peakfinder(EKG.signal, thresholdCandidates(iThreshold), minSampsBetweenPeaks);
    catch
        candidatePeaks = [];
    end
    if ~isempty(candidatePeaks) && size(candidatePeaks, 2) >= 2
        candidatePeaks = candidatePeaks(all(isfinite(candidatePeaks(:,1:2)), 2), 1:2);
    else
        candidatePeaks = [];
    end
    if size(candidatePeaks, 1) >= 2
        detectedPeaks = candidatePeaks;
        selectedThreshold = thresholdCandidates(iThreshold);
        break
    end
end

if isempty(detectedPeaks)
    warndlg('No ECG peaks were found. Lower the threshold or invert the ECG signal, then try again.','Warning!');
    return
end

if obj.hasInspector()
    obj.inspector.beginUiEdit();
end
EKG.threshold = selectedThreshold;
EKG.peaks = detectedPeaks;
EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate; %in seconds
axes(findobj('Tag', 'AxesEkgPlot'));

EKG.time_second_beat = EKG.t_peaks(2); %in seconds
EKG.ibis = 1000*diff(EKG.t_peaks); %ibi in milliseconds
y = EKG.ibis;   %leave in ms
x=EKG.t_peaks(2:end);
t=(x-x(1)); %x in seconds; second beat at t=0
tMax = round(t(end));
xx=0:0.1:tMax;        % ibi interpolated to 10 Hz
yy = spline(t,y,xx);
EKG.ibi_spline = yy;
EKG.ibi_spline_t = xx+x(1);
if obj.hasInspector()
    obj.inspector.setPeaksFromUi(EKG.peaks(:,1), EKG.peaks(:,2));
end

obj.drawEkgPlot();
obj.drawIbiPlot();
obj.drawPsdPlot();
end

function initEkgControl(obj)


screen_size = get(0, 'ScreenSize');
screen_width = screen_size(3);
screen_height = screen_size(4);

% h0 = figure('Color',[0.92 0.86 0.78], ...
h0 = figure('Color',[0.84 0.8 0.73], ...
   'CloseRequestFcn', @(~,~)obj.exitHrv(), ...
   'MenuBar','none', ...
   'Name','EkgControl', ...
   'NumberTitle','off', ...
   'Position',[screen_width-358 screen_height-430 350 400], ...
   'Resize','off', ...
   'Tag','FigureEkgControl');
h1 = uicontrol('Parent',h0, ...
    'Callback', @(~,~)obj.invertEkgData(), ...
    'FontSize',10, ...
    'Position',[10 365 90 30], ...
    'String','Invert EKG', ...
    'Tag','PushbuttonEkgInvert');
% threshold control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
ht1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.029 0.700 0.257 0.200], ...
    'Title','Threshold', ...
    'Tag','ThresholdPanel');
h1 = uicontrol('Parent',ht1, ...
    'Callback', @(~,~)obj.moveThreshold(1), ...
    'FontSize',10, ...
    'Position',[2 34 40 30], ...
    'String','Up', ...
    'Tag','moveThresholdUp');
h1 = uicontrol('Parent',ht1, ...
    'Callback', @(~,~)obj.moveThreshold(-1), ...
    'FontSize',10, ...
    'Position',[44 34 40 30], ...
    'String','Down', ...
    'Tag','moveThresholdDown');
h1 = uicontrol('Parent',ht1, ...
    'Callback', @(~,~)obj.findPeaks(), ...
    'FontSize',10, ...
    'Position',[2 5 84 30], ...
    'String','Find Peaks', ...
    'Tag','PushbuttonFindPeaks');
% Navigation control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hekg1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.029 0.300 0.257 0.380], ...
    'Title','Navigation', ...
    'Tag','ThresholdPanel');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.setEkgHome(), ...
    'FontSize',10, ...
    'Position',[2 104 40 22], ...
    'String','Home', ...
    'Tag','PushbuttonEkgHome');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.zoomEkgOneMinute(), ...
    'FontSize',10, ...
    'Position',[46 104 40 22], ...
    'String','1 Min', ...
    'Tag','PushbuttonEkgZoomMinute');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.setEkgStart(), ...
    'FontSize',10, ...
    'Position',[2 72 40 22], ...
    'String','Start', ...
    'Tag','PushbuttonEkgStart');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.setEkgEnd(), ...
    'FontSize',10, ...
    'Position',[46 72 40 22], ...
    'String','End', ...
    'Tag','PushbuttonEkgEnd');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.changeEkgScale(-1), ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'Position',[2 40 40 22], ...
    'String','<-->', ...
    'Tag','PushbuttonSpreadPeaks');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.changeEkgScale(1), ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'Position',[46 40 40 22], ...
    'String','-><-', ...
    'Tag','PushbuttonSqueezePeaks');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.moveEkgScale(-1), ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'Position',[24 8 20 18], ...
    'String','<', ...
    'Tag','PushbuttonMoveLeft');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.fastScrollEkgScale(-1), ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'Position',[2 8 20 18], ...
    'String','<<', ...
    'Tag','PushbuttonMoveLeftFast');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.moveEkgScale(1), ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'Position',[46 8 20 18], ...
    'String','>', ...
    'Tag','PushbuttonMoveRight');
h1 = uicontrol('Parent',hekg1, ...
    'Callback', @(~,~)obj.fastScrollEkgScale(1), ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'Position',[68 8 20 18], ...
    'String','>>', ...
    'Tag','PushbuttonMoveRightFast');
% Peak control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hpeak1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.343 0.680 0.257 0.275], ...
    'Title','ECG peaks', ...
    'Tag','PeaksPanel');
h1 = uicontrol('Parent',hpeak1, ...
    'Callback', @(~,~)obj.addPeak(-1), ...
    'FontSize',10, ...
    'Position',[2 67 84 30], ...
    'String','Add Left', ...
    'Tag','PushbuttonAddLeft');
h1 = uicontrol('Parent',hpeak1, ...
    'Callback', @(~,~)obj.addPeak(1), ...
    'FontSize',10, ...
    'Position',[2 36 84 30], ...
    'String','Add Right', ...
    'Tag','PushbuttonAddRight');
h1 = uicontrol('Parent',hpeak1, ...
    'Callback', @(~,~)obj.deletePeak(), ...
    'FontSize',8, ...
    'Position',[2 5 84 30], ...
    'String','Delete Selected', ...
    'Tag','PushbuttonDeletePeak');
% Move Peak control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hmvpeak1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.343 0.440 0.257 0.200], ...
    'Title','Move Peak', ...
    'Tag','MovePeakPanel');
h1 = uicontrol('Parent',hmvpeak1, ...
    'Callback', @(~,~)obj.movePeak(4), ...
    'FontSize',10, ...
    'Position',[5 5 40 30], ...
    'String','Left', ...
    'Tag','PushbuttonLeft');
h1 = uicontrol('Parent',hmvpeak1, ...
    'Callback', @(~,~)obj.movePeak(6), ...
    'FontSize',10, ...
    'Position',[46 5 40 30], ...
    'String','Right', ...
    'Tag','PushbuttonRight');
h1 = uicontrol('Parent',hmvpeak1, ...
    'Callback', @(~,~)obj.movePeak(8), ...
    'FontSize',10, ...
    'Position',[5 36 40 30], ...
    'String','Up', ...
    'Tag','PushbuttonUp');
h1 = uicontrol('Parent',hmvpeak1, ...
    'Callback', @(~,~)obj.movePeak(2), ...
    'FontSize',10, ...
    'Position',[46 36 40 30], ...
    'String','Down', ...
    'Tag','PushbuttonDown');
% Move HF_lower control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hmvHFL1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.343 0.300 0.257 0.120], ...
    'Title','Move HF_lower', ...
    'Tag','MoveHFLPanel');
h1 = uicontrol('Parent',hmvHFL1, ...
    'Callback', @(~,~)obj.moveHF(1), ...
    'FontSize',10, ...
    'Position',[5 5 40 30], ...
    'String','Down', ...
    'Tag','PushbuttonUp');
h1 = uicontrol('Parent',hmvHFL1, ...
    'Callback', @(~,~)obj.moveHF(2), ...
    'FontSize',10, ...
    'Position',[46 5 40 30], ...
    'String','Up', ...
    'Tag','PushbuttonDown');
% Move HF_upper control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hmvHFU1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.343 0.170 0.257 0.120], ...
    'Title','Move HF_upper', ...
    'Tag','MoveHFLPanel');
h1 = uicontrol('Parent',hmvHFU1, ...
    'Callback', @(~,~)obj.moveHF(3), ...
    'FontSize',10, ...
    'Position',[5 5 40 30], ...
    'String','Down', ...
    'Tag','PushbuttonUp');
h1 = uicontrol('Parent',hmvHFU1, ...
    'Callback', @(~,~)obj.moveHF(4), ...
    'FontSize',10, ...
    'Position',[46 5 40 30], ...
    'String','Up', ...
    'Tag','PushbuttonDown');
% RSP panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hmvRSP = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.628 0.415 0.300 0.120], ...
    'Title','Respiratory', ...
    'Tag','Respiratory', ...
    'Visible','off');
h1 = uicontrol('Parent',hmvRSP, ...
    'Callback', @(~,~)obj.Resp(), ...
    'FontSize',10, ...
    'Position',[5 5 40 30], ...
    'String','Plot', ...
    'Tag','PushbuttonResp');
% RRI control panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hrri1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.628 0.251 0.300 0.140], ...
    'Title','IBI datapoints', ...
    'Tag','RriPanel');
h1 = uicontrol('Parent',hrri1, ...
    'Callback', @(~,~)obj.deleteRriPoint(), ...
    'FontSize',10, ...
    'Position',[22 13 60 30], ...
    'String','Delete', ...
    'Tag','PushbuttonDeleteRri');
% Save panel %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hbg1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.029 0.0025 0.583 0.129], ...
    'Title','Save', ...
    'Tag','SavePanel', ...
    'Visible','off');
h1 = uicontrol('Parent',hbg1, ...
    'Callback', @(~,~)obj.saveIbis(), ...
    'FontSize',10, ...
    'Position',[4 5 90 30], ...
    'String','IBIs', ...
    'Tag','SaveIbisbutton');
h1 = uicontrol('Parent',hbg1, ...
    'Callback', @(~,~)obj.saveIbiSpline(), ...
    'FontSize',10, ...
    'Position',[106 5 90 30], ...
    'String','IBIspline', ...
    'Tag','SaveIbiSplinebutton');
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hrv1 = uipanel('Parent',h0, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'Position',[0.628 0.6025 0.357 0.385], ...
    'Title','HRV', ...
    'Tag','HrvPanel');
h1 = uicontrol('Parent',hrv1, ...
    'Style','edit', ...
    'FontSize',10, ...
    'Position',[55 103 60 30], ...
    'String','', ...
    'Tag','LfEditBox');
h1 = uicontrol('Parent',hrv1, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'HorizontalAlignment','center', ...    
    'Position',[2 95 50 30], ...
    'String','LF:', ...
    'Style','text', ...
    'Tag','StaticTextLF');
h1 = uicontrol('Parent',hrv1, ...
    'Style','edit', ...
    'FontSize',10, ...
    'Position',[55 70 60 30], ...
    'String','', ...
    'Tag','HfEditBox');
h1 = uicontrol('Parent',hrv1, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'HorizontalAlignment','center', ...    
    'Position',[2 64 50 30], ...
    'String','HF:', ...
    'Style','text', ...
    'Tag','StaticTextHF');
h1 = uicontrol('Parent',hrv1, ...
    'Style','edit', ...
    'FontSize',10, ...
    'Position',[55 37 60 30], ...
    'String','', ...
    'Tag','LfHfEditBox');
h1 = uicontrol('Parent',hrv1, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'HorizontalAlignment','center', ...    
    'Position',[2 33 50 25], ...
    'String','LF/HF:', ...
    'Style','text', ...
    'Tag','StaticTextLFHF');
h1 = uicontrol('Parent',hrv1, ...
    'Style','edit', ...
    'FontSize',10, ...
    'Position',[55 4 60 30], ...
    'String','', ...
    'Tag','HrEditBox');
h1 = uicontrol('Parent',hrv1, ...
    'BackgroundColor',[0.84 0.8 0.73], ...
    'FontSize',10, ...
    'FontWeight','bold', ...
    'HorizontalAlignment','center', ...    
    'Position',[2 2 50 25], ...
    'String','HR:', ...
    'Style','text', ...
    'Tag','StaticTextHR');
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
h1 = uicontrol('Parent',h0, ...
    'Callback', @(~,~)obj.undoReview(), ...
    'FontSize',9, ...
    'FontWeight','bold', ...
    'Position',[8 10 52 30], ...
    'String','Undo', ...
    'Tag','UndoButton');
h1 = uicontrol('Parent',h0, ...
    'Callback', @(~,~)obj.startOverReview(), ...
    'FontSize',9, ...
    'FontWeight','bold', ...
    'Position',[64 10 74 30], ...
    'String','Start Over', ...
    'Tag','StartOverButton');
h1 = uicontrol('Parent',h0, ...
    'Callback', @(~,~)obj.exitWithoutSaving(), ...
    'FontSize',9, ...
    'FontWeight','bold', ...
    'Position',[142 10 96 30], ...
    'String','Exit No Save', ...
    'Tag','ExitNoSaveButton');
h1 = uicontrol('Parent',h0, ...
    'Callback', @(~,~)obj.exitHrv(), ...
    'FontSize',9, ...
    'FontWeight','bold', ...
    'Position',[242 10 98 30], ...
    'String','Save & Exit', ...
    'Tag','Exitbutton');
end

function initEkgPlot(obj)

screen_size = get(0, 'ScreenSize');
screen_width = screen_size(3);
screen_height = screen_size(4);

h0 = figure('Color',[0.84 0.8 0.73], ...
   'CloseRequestFcn', @(~,~)obj.exitHrv(), ...
   'MenuBar','none', ...
   'Name','EKG', ...
   'NumberTitle','off', ...
   'Position',[10 screen_height-430 screen_width-375 400], ...
   'Tag','FigureEkgPlot');
h1 = axes('Parent',h0, ...
   'CameraUpVector',[0 1 0], ...
   'Color','none', ...
   'Position',[0.08 0.11 0.85 0.8], ...
   'Tag','AxesEkgPlot', ...
   'XColor',[0 0 0], ...
   'XGrid','on', ...
   'YColor',[0 0 0], ...
   'YGrid','on', ...
   'buttondownfcn', @(~,~)obj.moveSelectedPeak()); % callback moveSelectedLine when ever clicked on the axis
   h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 -0.07 9.16], ...
   'String','Time (sec)', ...
   'Tag','AxesEkgPlotXLabel', ...
   'VerticalAlignment','cap');
set(get(h2,'Parent'),'XLabel',h2);
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[-0.07 0.50 9.16], ...
   'Rotation',90, ...
   'String','Voltage', ...
   'Tag','AxesEkgPlotYLabel', ...
   'VerticalAlignment','baseline');
set(get(h2,'Parent'),'YLabel',h2);
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 1.02 9.16], ...
   'String','EKG', ...
   'Tag','AxesStartlePlotTitle', ...
   'VerticalAlignment','bottom');
set(get(h2,'Parent'),'Title',h2);
end

function initIbiPlot(obj)

screen_size = get(0, 'ScreenSize');
screen_width = screen_size(3);
screen_height = screen_size(4);

h0 = figure('Color',[0.84 0.8 0.73], ...
   'CloseRequestFcn', @(~,~)obj.exitHrv(), ...
   'MenuBar','none', ...
   'Name','IBI', ...
   'NumberTitle','off', ...
   'Position',[10 screen_height-870 screen_width-375 400], ...
   'Tag','FigureIbiPlot');
h1 = axes('Parent',h0, ...
   'CameraUpVector',[0 1 0], ...
   'Color','none', ...
   'Position',[0.08 0.11 0.85 0.8], ...
   'Tag','AxesIbiPlot', ...
   'XColor',[0 0 0], ...
   'XGrid','on', ...
   'YColor',[0 0 0], ...
   'YGrid','on', ...
   'buttondownfcn', @(~,~)obj.moveSelectedIbiPoint());
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 -0.07 9.16], ...
   'String','Time (sec)', ...
   'Tag','AxesIbiPlotXLabel', ...
   'VerticalAlignment','cap');
set(get(h2,'Parent'),'XLabel',h2);
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[-0.07 0.50 9.16], ...
   'Rotation',90, ...
   'String','IBI (msec)', ...
   'Tag','AxesIbiPlotYLabel', ...
   'VerticalAlignment','baseline');
set(get(h2,'Parent'),'YLabel',h2);
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 1.02 9.16], ...
   'String','IBI', ...
   'Tag','AxesIbiPlotTitle', ...
   'VerticalAlignment','bottom');
set(get(h2,'Parent'),'Title',h2);
end

function addRriPoint(obj)
%
% function addRriPoint
%

global EKG;

if isempty(EKG.peaks) || numel(EKG.peaks) < 2
    warndlg('At least two peaks are required to add an IBI point.','Warning!');
    return
end

rriPeaksIdx = obj.getRriPeaksIdx();
selected_sample = obj.getSelectedIbiPeakIdx();
if isempty(selected_sample)
    return
end

pos = find(rriPeaksIdx == selected_sample, 1, 'first');
if isempty(pos) || pos <= 1
    warndlg('Selected IBI point is invalid. Try again.','Warning!');
    return
end

prev_peak = pos - 1;
t_visible = rriPeaksIdx / EKG.sampRate;
add_peak_time = (t_visible(prev_peak) + t_visible(pos)) / 2;
add_peak_sample = round(add_peak_time * EKG.sampRate);

if add_peak_sample <= 1 || add_peak_sample >= numel(EKG.signal)
    warndlg('New IBI point is out of bounds. Try again.','Warning!');
    return
end

if obj.hasInspector()
    obj.inspector.beginUiEdit();
end
rriPeaksIdx = [rriPeaksIdx(1:pos-1); add_peak_sample; rriPeaksIdx(pos:end)];
obj.setRriPeaksIdx(rriPeaksIdx);
obj.appendRriLog("insert", add_peak_sample, add_peak_sample, "ui_rri_add", "rri_peak");

obj.drawIbiPlot();
obj.drawPsdPlot();
end

function deleteRriPoint(obj)
%
% function deleteRriPoint
%

global EKG;

if isempty(EKG.peaks) || numel(EKG.peaks) < 2
    warndlg('At least two peaks are required to delete an IBI point.','Warning!');
    return
end

rriPeaksIdx = obj.getRriPeaksIdx();
selected_sample = obj.getSelectedIbiPeakIdx();
if isempty(selected_sample)
    return
end

pos = find(rriPeaksIdx == selected_sample, 1, 'first');
if isempty(pos) || pos <= 1
    warndlg('Selected IBI point is invalid. Try again.','Warning!');
    return
end

if obj.hasInspector()
    obj.inspector.beginUiEdit();
end
invalidIdx = obj.getRriInvalidIdx();
invalidIdx(end+1,1) = selected_sample;
obj.setRriInvalidIdx(invalidIdx);
obj.appendRriLog("delete", selected_sample, selected_sample, "ui_rri_delete", "rri_invalid");

obj.drawIbiPlot();
obj.drawPsdPlot();
end

function moveRriPoint(obj, direction)
%
% function moveRriPoint(direction)
%
% direction -1=left, 1=right

global EKG;

if isempty(EKG.peaks) || numel(EKG.peaks) < 2
    warndlg('At least two peaks are required to move an IBI point.','Warning!');
    return
end

rriPeaksIdx = obj.getRriPeaksIdx();
selected_sample = obj.getSelectedIbiPeakIdx();
if isempty(selected_sample)
    return
end

pos = find(rriPeaksIdx == selected_sample, 1, 'first');
if isempty(pos) || pos <= 1
    warndlg('Selected IBI point is invalid. Try again.','Warning!');
    return
end

oldSampleIdx = selected_sample;
newSampleIdx = oldSampleIdx + direction * EKG.plot.incrLR;
prevSample = rriPeaksIdx(pos - 1);
if pos < numel(rriPeaksIdx)
    nextSample = rriPeaksIdx(pos + 1);
else
    nextSample = numel(EKG.signal);
end
if newSampleIdx <= prevSample || newSampleIdx >= nextSample || newSampleIdx < 1
    warndlg('New IBI point is out of order. Try again.','Warning!');
    return
end

if obj.hasInspector()
    obj.inspector.beginUiEdit();
end
rriPeaksIdx(pos) = newSampleIdx;
obj.setRriPeaksIdx(rriPeaksIdx);
invalidIdx = obj.getRriInvalidIdx();
if any(invalidIdx == oldSampleIdx)
    invalidIdx(invalidIdx == oldSampleIdx) = newSampleIdx;
    obj.setRriInvalidIdx(invalidIdx);
end
if direction < 0
    note = "ui_rri_move_left";
else
    note = "ui_rri_move_right";
end
obj.appendRriLog("move", oldSampleIdx, newSampleIdx, note, "rri_peak");

obj.drawIbiPlot();
obj.drawPsdPlot();
end

function moveSelectedIbiPoint(obj)
%
% function moveSelectedIbiPoint
%

global EKG;

rriPeaksIdx = obj.getRriPeaksIdx();
selected_sample = obj.getSelectedIbiPeakIdx(false);
if isempty(selected_sample)
    return
end
pos = find(rriPeaksIdx == selected_sample, 1, 'first');
if isempty(pos) || pos <= 1
    return
end

axes(findobj('Tag', 'AxesIbiPlot'));
newPeakPosition  = get(gca,'CurrentPoint');
newPeakPositionX = newPeakPosition(1,1);

prevTime = rriPeaksIdx(pos - 1) / EKG.sampRate;
if pos < numel(rriPeaksIdx)
    nextTime = rriPeaksIdx(pos + 1) / EKG.sampRate;
else
    nextTime = EKG.plot.maxTime;
end

if newPeakPositionX <= prevTime || newPeakPositionX >= nextTime
    warndlg('New IBI point is out of order. Try again.','Warning!');
    return
end

oldSampleIdx = selected_sample;
newSampleIdx = round(newPeakPositionX * EKG.sampRate);
if newSampleIdx < 1 || newSampleIdx > numel(EKG.signal)
    return
end

if obj.hasInspector()
    obj.inspector.beginUiEdit();
end
rriPeaksIdx(pos) = newSampleIdx;
obj.setRriPeaksIdx(rriPeaksIdx);
invalidIdx = obj.getRriInvalidIdx();
if any(invalidIdx == oldSampleIdx)
    invalidIdx(invalidIdx == oldSampleIdx) = newSampleIdx;
    obj.setRriInvalidIdx(invalidIdx);
end
obj.appendRriLog("move", oldSampleIdx, newSampleIdx, "ui_rri_move_click", "rri_peak");

obj.drawIbiPlot();
obj.drawPsdPlot();
end

function selected_peak = getSelectedIbiPeakIdx(obj, warnIfEmpty)
%
% function selected_peak = getSelectedIbiPeakIdx
%

global EKG;

if nargin < 2
    warnIfEmpty = true;
end

selected_peak = [];
hAx = findobj('Tag', 'AxesIbiPlot');
if isempty(hAx) || ~ishandle(hAx)
    return
end
axes(hAx);
h = findobj(gca,'Type','text','-regexp','Tag','^ibi[0-9]+$');
numPeaks = numel(h);
for iPeak = 1:numPeaks
	test = get(h(iPeak),'userdata');
    if isnumeric(test) && numel(test) == 3 && sum(test == [1 1 0]) > 2
        tag = get(h(iPeak),'Tag');
        if isstring(tag)
            tag = char(tag);
        end
        if ischar(tag) && strncmp(tag, 'ibi', 3)
            idx = str2double(tag(4:end));
            if isfinite(idx)
                selected_peak = [selected_peak idx];
            end
        end
    end
end
if length(selected_peak) > 1
    warndlg('More than one IBI point is selected. Try again.','Warning!');
    selected_peak = selected_peak(1);
elseif isempty(selected_peak) && warnIfEmpty
    warndlg('An IBI point must be selected. Try again.','Warning!');
end
end

function initPsdPlot(obj)

screen_size = get(0, 'ScreenSize');
screen_width = screen_size(3);
screen_height = screen_size(4);

h0 = figure('Color',[0.84 0.8 0.73], ...
   'CloseRequestFcn', @(~,~)obj.exitHrv(), ...
   'MenuBar','none', ...
   'Name','PSD', ...
   'NumberTitle','off', ...
   'Position',[screen_width-358 screen_height-870 350 400], ...
   'Resize','off', ...
   'Tag','FigurePsdPlot');
h1 = axes('Parent',h0, ...
   'CameraUpVector',[0 1 0], ...
   'Color', 'none', ...
   'Position',[0.10 0.11 0.8 0.8], ...
   'Tag','AxesPsdPlot', ...
   'XColor',[0 0 0], ...
   'XGrid','on', ...
   'YColor',[0 0 0], ...
   'YGrid','on');
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 -0.07 9.16], ...
   'String','Hz', ...
   'Tag','AxesPsdPlotXLabel', ...
   'VerticalAlignment','cap');
set(get(h2,'Parent'),'XLabel',h2);
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[-0.07 0.50 9.16], ...
   'Rotation',90, ...
   'String','ms^2/Hz', ...
   'Tag','AxesPsdPlotYLabel', ...
   'VerticalAlignment','baseline');
set(get(h2,'Parent'),'YLabel',h2);
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 1.02 9.16], ...
   'String','PSD', ...
   'Tag','AxesStartlePlotTitle', ...
   'VerticalAlignment','bottom');
set(get(h2,'Parent'),'Title',h2);
end

function invertEkgData(obj)
%
% function invertEkgData
%
global EKG;

EKG.signal = -EKG.signal;
obj.drawEkgPlot();
end

function moveEkgScale(obj, x)
%
%
%

global EKG;

t_width = floor(EKG.plot.endTime - EKG.plot.startTime);

if x < 0 
	EKG.plot.startTime = max(round(EKG.plot.startTime - t_width + 1),0);
	EKG.plot.endTime = EKG.plot.startTime + t_width;
else
	EKG.plot.endTime = min(round(EKG.plot.endTime + t_width - 1),ceil(EKG.plot.maxTime));
	EKG.plot.startTime = EKG.plot.endTime - t_width;
end
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function setEkgHome(obj)

global EKG;

EKG.plot.startTime = 0;
EKG.plot.widthTime = EKG.plot.maxTime;
EKG.plot.incrLR = EKG.plot.widthTime;
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function setEkgStart(obj)

global EKG;

windowLength = min(60, EKG.plot.maxTime);
if windowLength <= 0
    return
end
EKG.plot.startTime = 0;
EKG.plot.widthTime = windowLength;
EKG.plot.incrLR = windowLength;
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function setEkgEnd(obj)

global EKG;

windowLength = min(60, EKG.plot.maxTime);
if windowLength <= 0
    return
end
EKG.plot.startTime = max(0, EKG.plot.maxTime - windowLength);
EKG.plot.widthTime = windowLength;
EKG.plot.incrLR = windowLength;
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function zoomEkgOneMinute(obj)

global EKG;

windowLength = min(60, EKG.plot.maxTime);
if windowLength <= 0
    return
end
centerTime = EKG.plot.maxTime / 2;
startTime = centerTime - windowLength / 2;
if startTime < 0
    startTime = 0;
end
if startTime + windowLength > EKG.plot.maxTime
    startTime = max(0, EKG.plot.maxTime - windowLength);
end
EKG.plot.startTime = startTime;
EKG.plot.widthTime = windowLength;
EKG.plot.incrLR = windowLength;
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function fastScrollEkgScale(obj, direction)

global EKG;

windowLength = EKG.plot.endTime - EKG.plot.startTime;
if ~isfinite(windowLength) || windowLength <= 0
    return
end
shiftSeconds = 300;
if shiftSeconds > EKG.plot.maxTime
    shiftSeconds = EKG.plot.maxTime;
end
if direction < 0
    startTime = EKG.plot.startTime - shiftSeconds;
else
    startTime = EKG.plot.startTime + shiftSeconds;
end
maxStart = max(0, EKG.plot.maxTime - windowLength);
if startTime < 0
    startTime = 0;
elseif startTime > maxStart
    startTime = maxStart;
end
EKG.plot.startTime = startTime;
EKG.plot.endTime = EKG.plot.startTime + windowLength;
EKG.plot.incrLR = windowLength;
obj.drawEkgPlot();
obj.drawIbiPlot();
end

function moveHF(obj, direction)
%
% function moveHF(direction)
%
% direction 1=HF_lower down; 2=HF_lower up; 3=HF_upper down; 4=HF_upper up


global EKG;

if direction < 3   %move HF_lower
    if direction == 1
        EKG.HF_lower = EKG.HF_lower - 0.01;
    else
        EKG.HF_lower = EKG.HF_lower + 0.01;
    end
else   %move HF_upper
    if direction == 3
        EKG.HF_upper = EKG.HF_upper - 0.01;
    else
        EKG.HF_upper = EKG.HF_upper + 0.01;
    end
end

obj.drawPsdPlot();
end

function movePeak(obj, direction)
%
% function movePeak(direction)
%
% direction 8=up; 2=down; 4=left; 6=right


global EKG;

selected_peak = obj.getSingleSelectedEcgPeakIdx(true);
if isempty(selected_peak)
    return
end

axes(findobj('Tag', 'AxesEkgPlot'));

if obj.hasInspector()
    oldSampleIdx = EKG.peaks(selected_peak, 1);
    switch(direction)
        case 8
            newAmplitude = EKG.peaks(selected_peak,2) + EKG.plot.incrUpDn;
            obj.inspector.updatePeakAmplitude(oldSampleIdx, newAmplitude, "ui_amp_up");
        case 2
            newAmplitude = EKG.peaks(selected_peak,2) - EKG.plot.incrUpDn;
            obj.inspector.updatePeakAmplitude(oldSampleIdx, newAmplitude, "ui_amp_down");
        case 6
            newSampleIdx = EKG.peaks(selected_peak,1) + EKG.plot.incrLR;
            obj.inspector.movePeak(oldSampleIdx, newSampleIdx, "ui_move_right");
        case 4
            newSampleIdx = EKG.peaks(selected_peak,1) - EKG.plot.incrLR;
            obj.inspector.movePeak(oldSampleIdx, newSampleIdx, "ui_move_left");
        otherwise
            disp(['Invalid direction: ' num2str(direction)]);
    end
    return
end

EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;

switch(direction)
    case 8
        EKG.peaks(selected_peak,2) = EKG.peaks(selected_peak,2) + EKG.plot.incrUpDn;
    case 2
        EKG.peaks(selected_peak,2) = EKG.peaks(selected_peak,2) - EKG.plot.incrUpDn;
    case 6
        EKG.peaks(selected_peak,1) = EKG.peaks(selected_peak,1) + EKG.plot.incrLR;
	EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;
	%update indxPeaks
		EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime); 
		EKG.ibis = 1000*diff(EKG.t_peaks); %ibi in milliseconds
		y = EKG.ibis;   %leave in ms
		x=EKG.t_peaks(2:end);
		t=(x-x(1)); %x in seconds; second beat at t=0
		tMax = round(t(end));
		xx=0:0.1:tMax;        % ibi interpolated to 10 Hz
		yy = spline(t,y,xx);
		EKG.ibi_spline = yy;
		EKG.ibi_spline_t = xx+x(1);
    case 4
        EKG.peaks(selected_peak,1) = EKG.peaks(selected_peak,1) - EKG.plot.incrLR;
		EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;
		%update indxPeaks
		EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime); 
		EKG.ibis = 1000*diff(EKG.t_peaks); %ibi in milliseconds
		y = EKG.ibis;  %leave in ms
		x=EKG.t_peaks(2:end);
		t=(x-x(1)); %x in seconds; second beat at t=0
		tMax = round(t(end));
		xx=0:0.1:tMax;        % ibi interpolated to 10 Hz
		yy = spline(t,y,xx);
		EKG.ibi_spline = yy;
		EKG.ibi_spline_t = xx+x(1);
   otherwise
        disp(['Invalid direction: ' num2str(direction)]);
        return
end

%----------------------------move by click----------------------------

%---------------------  have to add bottondown on ekg axis
%-----------------add if selected "o" is red----------------
%-----------------------you might have to make a new function, such as
%moreSelected peak

% newPeakPosition  = get(gca,'CurrentPoint');
% newPeakPositionX = get(gca,'CurrentPoint');
% newPeakPositionY = get(gca,'CurrentPoint');
% 
% if ((EKG.peaks(selected_peak-1,1)/EKG.sampRate) < newPeakPositionX(1,1) < (EKG.peaks(selected_peak+1,1)/EKG.sampRate))  
%          EKG.peaks(selected_peak,2) = newPeakPositionY(1,2);
%   else
%              warndlg('New peak is out of order! Please try again!','Warning!');
% end
% 
% a = selected_peak
% a_1 = selected_peak + 1
% a_2 = selected_peak -1
% 
% b = EKG.peaks(selected_peak,1)
% c = EKG.peaks(selected_peak,2)

%-----------------------------------------------------------------------



obj.drawIbiPlot();
obj.drawEkgPlot();
obj.drawPsdPlot();
end

function moveSelectedLine(obj)

global EKG;

if EKG.rspBoundExists == 1

if (get(findobj('Tag', 'lowerBound'), 'color')) == [0 1 1]
    
delete(findobj('Tag', 'lowerBound')) % remove line if present
axes(findobj('Tag', 'AxesRspPlot'));
pointDown = get(gca,'CurrentPoint');
pointDown = pointDown(1,1);
EKG.RSPpointDown = pointDown;

line([pointDown pointDown],[EKG.rspMin EKG.rspMax],'color',[1 1 1], 'userdata',[0 1 1], 'LineWidth', 1.25, ...
                     'parent',gca, 'Tag', 'lowerBound',...
                     'buttondownfcn', ...
					['tmpstrr = get(gco, ''userdata'');' ...
					 'set(gco, ''userdata'', get(gco, ''color''));' ...
					 'set(gco, ''color'', tmpstrr); clear tmpstrr;' ...
                     ] ); 
end

if (get(findobj('Tag', 'upperBound'), 'color')) == [0 1 1]
    
delete(findobj('Tag', 'upperBound')) % remove line if present
axes(findobj('Tag', 'AxesRspPlot'));
pointUp = get(gca,'CurrentPoint');
pointUp = pointUp(1,1); 
EKG.RSPpointUp = pointUp;
                 
line([pointUp pointUp],[EKG.rspMin EKG.rspMax],'color',[1 1 1], 'userdata',[0 1 1], 'LineWidth', 1.25, ...
                     'parent',gca, 'Tag', 'upperBound',...
                     'buttondownfcn', ...
					['tmpstrr = get(gco, ''userdata'');' ...
					 'set(gco, ''userdata'', get(gco, ''color''));' ...
					 'set(gco, ''color'', tmpstrr); clear tmpstrr;'] );  
       
end
 obj.drawPsdPlot();  
end
end

function moveSelectedPeak(obj)

global EKG;

selected_peak = obj.getSelectedEcgPeakIdx(false);

axes(findobj('Tag', 'AxesEkgPlot'));
newPeakPosition  = get(gca,'CurrentPoint');
newPeakPositionX = newPeakPosition(1,1);
newPeakPositionY = newPeakPosition(1,2);

% ------------------------if selected "o" is red execute the code bellow----------------

%  a = EKG.peaks(selected_peak,1)/EKG.sampRate
%     b = newPeakPositionX
    
if isempty(selected_peak)
    return
end

if length(selected_peak) > 1
    warndlg('More than one peak is selected. Try again.','Warning!');
    return
end

EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;

nPeaks = size(EKG.peaks, 1);
leftBoundSec = 0;
rightBoundSec = EKG.plot.maxTime;
if selected_peak > 1
    leftBoundSec = EKG.peaks(selected_peak-1,1)/EKG.sampRate;
end
if selected_peak < nPeaks
    rightBoundSec = EKG.peaks(selected_peak+1,1)/EKG.sampRate;
end

if (leftBoundSec < newPeakPositionX) && (newPeakPositionX < rightBoundSec)
         if obj.hasInspector()
             oldSampleIdx = EKG.peaks(selected_peak,1);
             newSampleIdx = ceil(newPeakPositionX*EKG.sampRate);
             newAmplitude = ceil(newPeakPositionY);
             obj.inspector.movePeak(oldSampleIdx, newSampleIdx, "ui_move_click", newAmplitude);
             return
         end
         EKG.peaks(selected_peak,1) = ceil(newPeakPositionX*EKG.sampRate);
         EKG.peaks(selected_peak,2) = ceil(newPeakPositionY);
         
         EKG.t_peaks = EKG.peaks(:,1)/EKG.sampRate;
            
	%update indxPeaks
		EKG.indxPeaks = find(EKG.t_peaks >= EKG.plot.startTime & EKG.t_peaks <= EKG.plot.endTime); 
		EKG.ibis = 1000*diff(EKG.t_peaks); %ibi in milliseconds
		y = EKG.ibis;   %leave in ms
		x=EKG.t_peaks(2:end);
		t=(x-x(1)); %x in seconds; second beat at t=0
		tMax = round(t(end));
		xx=0:0.1:tMax;  %ibi interpolated to 10 Hz
		yy = spline(t,y,xx);
		EKG.ibi_spline = yy;
		EKG.ibi_spline_t = xx+x(1);

% a = selected_peak
% a_1 = selected_peak + 1
% a_2 = selected_peak -1
% 
% c = EKG.peaks(selected_peak,1)
% ct = EKG.peaks(selected_peak,1)
% c1 = newPeakPositionX
% d = EKG.peaks(selected_peak,2)

obj.drawIbiPlot();
obj.drawEkgPlot();
obj.drawPsdPlot();    

  else
             warndlg('New peak is out of order! Please try again!','Warning!');
end


end

function moveThreshold(~, x)
%
%
%

global EKG;
if x > 0  %move up
    EKG.threshold = EKG.threshold + EKG.threshold/20;  %move up 5%
else
    EKG.threshold = EKG.threshold - EKG.threshold/20;  %move down 5%
end

axes(findobj('Tag', 'AxesEkgPlot'));
% remove line if present
delete(findobj('Tag', 'LineEkgDataThreshold'))
xThreshold = [EKG.plot.startTime EKG.plot.endTime];
yThreshold = [EKG.threshold EKG.threshold];
line(xThreshold,yThreshold,'color','cyan','Tag', 'LineEkgDataThreshold');
end

function Resp(obj)

global EKG;

set (findobj('Tag', 'AxesEkgPlot'), 'Position',[0.08 0.11 0.85 0.4], ...
    'Color', 'none');  
%--------------------------------- initPlot-------------------------%

h = findobj('Tag', 'FigureEkgPlot');

h11 = axes('Parent',h, ...
   'CameraUpVector',[0 1 0], ...
   'Color', 'none', ...
   'Position',[0.08 0.51 0.85 0.4], ...
   'Tag','AxesRspPlot', ...
   'XColor',[1 0 0], ...
   'XGrid','on', ...
   'YColor',[1 0 0], ...
   'YAxisLocation','right',...
   'XAxisLocation','top', ...
   'YGrid','on',...
   'buttondownfcn', @(~,~)obj.moveSelectedLine()); % callback moveSelectedLine when ever clicked on the axis
h2 = text('Parent',h11, ...
   'Color',[1 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[-0.07 0.50 9.16], ...
   'Rotation',90, ...
   'String','Respiratory', ...
   'Tag','AxesRspPlotYLabel', ...
   'VerticalAlignment','baseline');
set(get(h2,'Parent'),'YLabel',h2); 
   h2 = text('Parent',h11, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[0.50 -0.07 9.16], ...
   'String','Respiratory Time (sec)', ...
   'Tag','AxesRspPlotXLabel', ... 
   'VerticalAlignment','cap');
set(get(h2,'Parent'),'XLabel',h2);

%--------------------------------- initPSDPlot-------------------------%

h1 = axes('Parent',findobj('Tag', 'FigurePsdPlot') , ...
   'CameraUpVector',[0 1 0], ...
   'Color', 'none', ...
   'Position',[0.10 0.11 0.8 0.8], ...
   'Tag','AxesRSPPsdPlot', ...
   'XColor',[0 0 0], ...
   'XGrid','off', ...
   'YColor',[0 0 0], ...
   'YGrid','off', ...
   'YAxisLocation','right');
h2 = text('Parent',h1, ...
   'Color',[0 0 0], ...
   'HandleVisibility','off', ...
   'HorizontalAlignment','center', ...
   'Position',[-0.07 0.50 9.16], ...
   'Rotation',90, ...
   'String','ms^2/Hz', ...
   'Tag','AxesRSPPsdPlotYLabel', ...
   'VerticalAlignment','baseline');
set(get(h2,'Parent'),'YLabel',h2);

%--------------------------------- getRspData-------------------------%

switch EKG.dataSource
    case 'acq'
        if isempty(EKG.parameter2)  % RESP channel not specified
            prompt = {'Enter RESP channel:'};
			dlg_title = 'Input RESP channel';
			num_lines = 1;
			answer = inputdlg(prompt,dlg_title,num_lines);
			EKG.parameter2 = str2num(answer{1});
		end
        [ffname,ffpath]=uigetfile({'*.acq'});
        ffileName = [ffpath ffname];
        EKG.RSP.inFile = ffileName(1:end-4);
        try,
        [ACQsampleRate,ACQtimeAxis,chanData] = readACQFile(EKG.RSP.inFile);
        catch,
            [ACQsampleRate,nVarSampleDivider,chanData] = readVarSampRateACQ(EKG.RSP.inFile);
        end
        EKG.RSP.signal = chanData(EKG.parameter2,:);
        if length(EKG.RSP.signal) < length(EKG.signal)
            disp('Warning respiration signal is shorter than EKG signal');
            numAdd = length(EKG.signal) - length(EKG.RSP.signal);
            EKG.RSP.signal = [EKG.RSP.signal; repmat(EKG.RSP.signal(end),numAdd,1)];
        elseif length(EKG.RSP.signal) > length(EKG.signal)
            disp('Warning EKG signal is shorter than respiration signal');
            EKG.RSP.signal = EKG.RSP.signal(1:length(EKG.signal));
        end
    case 'text'
        [ffname,ffpath]=uigetfile('*.*');
        ffileName = [ffpath ffname];
        EKG.RSP.signal = dlmread(ffileName);
        if length(EKG.RSP.signal) < length(EKG.signal)
            disp('Warning respiration signal is shorter than EKG signal');
            numAdd = length(EKG.signal) - length(EKG.RSP.signal);
            EKG.RSP.signal = [EKG.RSP.signal; repmat(EKG.RSP.signal(end),numAdd,1)];
        elseif length(EKG.RSP.signal) > length(EKG.signal)
            disp('Warning EKG signal is shorter than respiration signal');
            EKG.RSP.signal = EKG.RSP.signal(1:length(EKG.signal));
        end
        EKG.RSP.inFile = ffileName(1:end-4);
    otherwise
            disp([EKG.dataSource ' is not a valid data source']);
            return
end

%--------------------------------- drawRspPlot-------------------------%
if ~isempty(EKG.RSP.signal)

iniLower = EKG.plot.startTime + floor(EKG.plot.endTime - EKG.plot.startTime)*1/3; %initial position of lower bound
iniUpper = EKG.plot.startTime + floor(EKG.plot.endTime - EKG.plot.startTime)*2/3; %initial position of upper bound



obj.drawEkgPlot();  %darwRspPlot in drawEkgPlot needs to run before the following code to set the values of EKG.rspMin and EKG.rspMax

axes(findobj('Tag', 'AxesRspPlot'));

line([iniLower iniLower],[EKG.rspMin EKG.rspMax],'color',[1 1 1], 'userdata',[0 1 1], 'LineWidth', 1.25, ...
                     'parent',gca, 'Tag', 'lowerBound', ...
                     'buttondownfcn', ...
					['tmpstrr = get(gco, ''userdata'');' ...
					 'set(gco, ''userdata'', get(gco, ''color''));' ...
					 'set(gco, ''color'', tmpstrr); clear tmpstrr;'] );  %draw lower bound line

line([iniUpper iniUpper],[EKG.rspMin EKG.rspMax],'color',[1 1 1], 'userdata',[0 1 1], 'LineWidth', 1.25, ...
                     'parent',gca, 'Tag', 'upperBound',...
                     'buttondownfcn', ...
					['tmpstrr = get(gco, ''userdata'');' ...
					 'set(gco, ''userdata'', get(gco, ''color''));' ...
					 'set(gco, ''color'', tmpstrr); clear tmpstrr;'] );  %draw upper bound line
                 
EKG.rspBoundExists = 1; %line exists now

end


obj.drawPsdPlot();
end

function saveIbis(~)
%
% function saveIbis
%

global EKG;

ibi_out = zeros(length(EKG.ibis),2);
ibi_out(:,2) = EKG.ibis';
ibi_out(1,1) = 1000*EKG.time_second_beat;
for iBeat = 2:length(EKG.ibis)
	ibi_out(iBeat,1) = ibi_out(iBeat-1,1) + EKG.ibis(iBeat);
end
outFile = [EKG.inFile '_ibis.txt'];
dlmwrite(outFile,ibi_out,'delimiter','\t','precision','%8.0f');
end

function saveIbiSpline(~)
%
% function saveIbiSpline
%

global EKG;

ibi_out = zeros(length(EKG.ibi_spline),2);
ibi_out(:,2) = EKG.ibi_spline';
ibi_out(:,1) = 1000*EKG.ibi_spline_t';

%ibi_out(1,1) = 1000*EKG.time_second_beat;
%for iBeat = 2:length(EKG.ibi_spline)
%	ibi_out(iBeat,1) = ibi_out(iBeat-1,1) + EKG.ibi_spline(iBeat);
%end

outFile = [EKG.inFile '_ibi10Hz.txt'];
dlmwrite(outFile,ibi_out,'delimiter','\t','precision','%8.1f');
end

    end

    methods (Access=private)
        function tf = hasInspector(obj)
            tf = ~isempty(obj.inspector) && isvalid(obj.inspector);
        end

        function selected_peak = getSelectedEcgPeakIdx(~, warnIfEmpty)
            if nargin < 2
                warnIfEmpty = true;
            end

            global EKG;
            selected_peak = [];
            hAx = findobj('Tag', 'AxesEkgPlot');
            if isempty(hAx) || ~ishandle(hAx(1)) || isempty(EKG) || ~isfield(EKG, 'indxPeaks')
                if warnIfEmpty
                    warndlg('A peak must be selected. Try again.','Warning!');
                end
                return
            end

            hAx = hAx(1);
            h = findobj(hAx,'Type','text','-regexp','Tag','^peak[0-9]+$');
            numPeaks = numel(h);
            for iPeak = 1:numPeaks
                test = get(h(iPeak),'userdata');  % gets peaks from right to left
                if isnumeric(test) && numel(test) == 3 && sum(test == [1 1 0]) > 2
                    peakPos = numPeaks-(iPeak-1);
                    if peakPos >= 1 && peakPos <= numel(EKG.indxPeaks)
                        selected_peak = [selected_peak EKG.indxPeaks(peakPos)]; %#ok<AGROW>
                    end
                end
            end

            selected_peak = unique(selected_peak, 'stable');
            if isempty(selected_peak) && warnIfEmpty
                warndlg('A peak must be selected. Try again.','Warning!');
            end
        end

        function selected_peak = getSingleSelectedEcgPeakIdx(obj, warnIfEmpty)
            if nargin < 2
                warnIfEmpty = true;
            end

            selected_peak = obj.getSelectedEcgPeakIdx(warnIfEmpty);
            if numel(selected_peak) > 1
                warndlg('More than one peak is selected. Try again.','Warning!');
                selected_peak = [];
            end
        end

        function appendRriLog(obj, action, peakBefore, peakAfter, note, editTarget)
            if ~obj.hasInspector()
                return
            end
            if nargin < 5
                note = "";
            end
            if nargin < 6 || strlength(editTarget) == 0
                editTarget = "";
            end
            obj.inspector.logRriEdit(action, peakBefore, peakAfter, note, editTarget);
        end

        function [visibleIdx, t_visible, ibis_all, validIbiMask, ibi_spline_t, ibi_spline] = getVisibleIbiSeries(obj)
            global EKG;
            rriPeaksIdx = obj.getRriPeaksIdx();
            visibleIdx = rriPeaksIdx(:);
            if isempty(visibleIdx)
                t_visible = [];
                ibis_all = [];
                validIbiMask = [];
                ibi_spline_t = [];
                ibi_spline = [];
                return
            end
            t_visible = visibleIdx / EKG.sampRate;
            if numel(t_visible) < 2
                ibis_all = [];
                validIbiMask = [];
                ibi_spline_t = [];
                ibi_spline = [];
                return
            end
            ibis_all = 1000*diff(t_visible);
            if isfield(EKG, 'rriCapSampleIdx') && isfield(EKG, 'rriCapValuesMs') && ...
                    ~isempty(EKG.rriCapSampleIdx) && ~isempty(EKG.rriCapValuesMs)
                capSampleIdx = double(EKG.rriCapSampleIdx(:));
                capValuesMs = double(EKG.rriCapValuesMs(:));
                if numel(capSampleIdx) == numel(capValuesMs)
                    ibiSampleIdx = rriPeaksIdx(2:end);
                    [hasCap, capLoc] = ismember(ibiSampleIdx, capSampleIdx);
                    if any(hasCap)
                        ibis_all(hasCap) = capValuesMs(capLoc(hasCap));
                    end
                end
            end
            invalidIdx = obj.getRriInvalidIdx();
            if isempty(invalidIdx)
                validIbiMask = true(size(ibis_all));
            else
                validIbiMask = ~ismember(rriPeaksIdx(2:end), invalidIdx);
            end
            if ~any(validIbiMask)
                ibi_spline = [];
                ibi_spline_t = [];
                return
            end
            y = ibis_all(validIbiMask);
            x = t_visible(2:end);
            x = x(validIbiMask);
            if numel(x) < 2
                ibi_spline = [];
                ibi_spline_t = [];
                return
            end
            t = (x - x(1));
            tMax = round(t(end));
            if tMax < 0
                ibi_spline = [];
                ibi_spline_t = [];
                return
            end
            xx = 0:0.1:tMax;
            yy = spline(t, y, xx);
            ibi_spline = yy;
            ibi_spline_t = xx + x(1);
        end

        function rriPeaksIdx = getRriPeaksIdx(obj)
            global EKG;
            if isfield(EKG, 'rriCustomActive') && EKG.rriCustomActive && ...
                    isfield(EKG, 'rriPeaksIdx') && ~isempty(EKG.rriPeaksIdx)
                rriPeaksIdx = EKG.rriPeaksIdx;
            elseif isfield(EKG, 'peaks') && ~isempty(EKG.peaks)
                rriPeaksIdx = EKG.peaks(:,1);
            else
                rriPeaksIdx = zeros(0,1);
            end
            rriPeaksIdx = obj.sanitizeRriPeaks(rriPeaksIdx);
        end

        function setRriPeaksIdx(obj, rriPeaksIdx)
            global EKG;
            EKG.rriCustomActive = true;
            EKG.rriPeaksIdx = obj.sanitizeRriPeaks(rriPeaksIdx);
            if isfield(EKG, 'rriInvalidIdx')
                EKG.rriInvalidIdx = obj.sanitizeRriInvalidIdx(EKG.rriInvalidIdx, EKG.rriPeaksIdx);
            else
                EKG.rriInvalidIdx = zeros(0,1);
            end
        end

        function rriInvalidIdx = getRriInvalidIdx(obj)
            global EKG;
            if ~isfield(EKG, 'rriCustomActive') || ~EKG.rriCustomActive
                rriInvalidIdx = zeros(0,1);
                return
            end
            if isfield(EKG, 'rriInvalidIdx') && ~isempty(EKG.rriInvalidIdx)
                rriInvalidIdx = EKG.rriInvalidIdx;
            else
                rriInvalidIdx = zeros(0,1);
            end
            rriInvalidIdx = obj.sanitizeRriInvalidIdx(rriInvalidIdx, obj.getRriPeaksIdx());
        end

        function setRriInvalidIdx(obj, rriInvalidIdx)
            global EKG;
            EKG.rriCustomActive = true;
            EKG.rriInvalidIdx = obj.sanitizeRriInvalidIdx(rriInvalidIdx, obj.getRriPeaksIdx());
        end

        function rriPeaksIdx = sanitizeRriPeaks(~, rriPeaksIdx)
            global EKG;
            if isempty(rriPeaksIdx)
                rriPeaksIdx = zeros(0,1);
                return
            end
            rriPeaksIdx = double(rriPeaksIdx(:));
            rriPeaksIdx = rriPeaksIdx(isfinite(rriPeaksIdx));
            rriPeaksIdx = round(rriPeaksIdx);
            rriPeaksIdx = rriPeaksIdx(rriPeaksIdx >= 1 & rriPeaksIdx <= numel(EKG.signal));
            rriPeaksIdx = unique(rriPeaksIdx, 'stable');
        end

        function rriInvalidIdx = sanitizeRriInvalidIdx(~, rriInvalidIdx, rriPeaksIdx)
            if isempty(rriInvalidIdx)
                rriInvalidIdx = zeros(0,1);
                return
            end
            if isempty(rriPeaksIdx) || numel(rriPeaksIdx) < 2
                rriInvalidIdx = zeros(0,1);
                return
            end
            rriInvalidIdx = double(rriInvalidIdx(:));
            rriInvalidIdx = rriInvalidIdx(isfinite(rriInvalidIdx));
            rriInvalidIdx = round(rriInvalidIdx);
            validPeaks = rriPeaksIdx(:);
            validIbiPeaks = validPeaks(2:end);
            rriInvalidIdx = rriInvalidIdx(ismember(rriInvalidIdx, validIbiPeaks));
            rriInvalidIdx = unique(rriInvalidIdx, 'stable');
        end
    end
end

