% expect: semilogx: x holds 0, on a logarithmic axis
% octave: omitting non-positive data in log plot
w = [0 0.25 0.5 1];
semilogx(w, w);
xlabel('frequency (Hz)');
ylabel('gain');
