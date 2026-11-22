% expect: plot: x has 4 values and y 3 (Octave stops: vector lengths must match)
% octave: vector lengths must match
w = [0.125 0.25 0.5 1];
H = [1 2 3; 4 5 6];
plot(w, 20*log10(abs(H(1,:))), 'r--');
xlabel('frequency (Hz)');
ylabel('level (dB)');
