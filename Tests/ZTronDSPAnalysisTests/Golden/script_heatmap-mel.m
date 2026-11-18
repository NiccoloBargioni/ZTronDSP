% Heat map: 3 rows, 6 columns
times = [0.25 0.3125 0.375 0.4375 0.5 0.5625];
row_values = [180.5 1250 6400.25];
values = [-52.1329689 -26.2411404 -59.6761589 -52.2240028 -46.0611916 -37.5521011; -47.4361801 -71.0281296 -51.8651772 -32.0740089 -42.3952637 -19.6350174; -51.7786484 -36.1712189 -66.7212524 -20.7539368 -38.0600395 -39.2247505];
imagesc(times, 1:numel(row_values), values);
axis xy;
colorbar;
xlabel('time (s)');
ylabel('row (mel band centre (Hz) in row_values)');
title('Heat map');
