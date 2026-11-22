% expect: semilogx: x holds -1, on a logarithmic axis
% octave: omitting non-positive data in log plot
x = [-1 1 2];
plot(x, x);
hold on;
semilogx([1 2 3], [1 2 3]);
hold off;
xlabel('frequency (Hz)');
ylabel('gain');
