% ZTronDSP calibration: time per call against size, one curve per implementation.
% gainKernel: C loop against vDSP_vsmul, crossover at 64
sizes_gainKernel = [8 64 512];
ns_gainKernel_1 = [2.5 20 160];
ns_gainKernel_2 = [9 12.25 40];
% laneExchange: C loop against vDSP_vmin, vDSP_vmax, no crossover on the grid
sizes_laneExchange = [8 4096];
ns_laneExchange_1 = [5.7999999999999998 457];
ns_laneExchange_2 = [12 978];
% medianGPU: Metal, one implementation measured
sizes_medianGPU = [69768 279072];
ns_medianGPU_1 = [1500000 0.30000000000000004];
subplot(2, 2, 1);
loglog(sizes_gainKernel, ns_gainKernel_1, 'o-');
hold on;
loglog(sizes_gainKernel, ns_gainKernel_2, 'x--');
hold off;
grid on;
xlabel('Block size (frames)');
ylabel('Time per call (ns)');
title('Gain kernel: C loop (o-), vDSP_vsmul (x--)');
subplot(2, 2, 2);
loglog(sizes_laneExchange, ns_laneExchange_1, 'o-');
hold on;
loglog(sizes_laneExchange, ns_laneExchange_2, 'x--');
hold off;
grid on;
xlabel('Length (elements)');
ylabel('Time per call (ns)');
title('Lane exchange: C loop (o-), vDSP_vmin, vDSP_vmax (x--)');
subplot(2, 2, 3);
loglog(sizes_medianGPU, ns_medianGPU_1, 'o-');
grid on;
xlabel('Kernel x bins x frames');
ylabel('Time per call (ns)');
title('Median of a spectrogram: Metal (o-)');
