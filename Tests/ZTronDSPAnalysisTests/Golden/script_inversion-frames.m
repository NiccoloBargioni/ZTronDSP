% Inversion report: Forward and back through Backward
% Every necessary condition holds.
predicted_error = 0.125001;
% first condition: holds, margin 0.5
% second condition: fails, margin -0.25
sample_rate = 1;
measured_snr = 78.736846155337062;
largest_error = 0.00016802549362182617;
original = [-1.35095894 -0.504778028 0.4446868 0.475562841 1.16363823 -0.162901729 0.168607548 -0.46539098 0.291978091 0.19502978 -0.769843817 0.194852263];
reconstruction = [-1.35107076 -0.504864514 0.444569439 0.475525409 1.16361809 -0.162905127 0.168439522 -0.465409994 0.29197681 0.195030943 -0.769860804 0.194881529];
subplot(3, 1, 1);
plot(0:numel(original)-1, original);
hold on;
plot(0:numel(original)-1, reconstruction, 'r--');
hold off;
xlabel('value');
ylabel('amplitude');
title('Original and reconstruction (dashed)');
grid on;
subplot(3, 1, 2);
plot(0:numel(original)-1, original - reconstruction);
xlabel('value');
ylabel('error');
title('Error');
grid on;
subplot(3, 1, 3);
plot((0:numel(original)-1) / numel(original), 20 * log10(abs(fft(original - reconstruction)) + 1e-300));
xlabel('cycles per value');
ylabel('level (dB)');
title('Spectrum of the error');
grid on;
