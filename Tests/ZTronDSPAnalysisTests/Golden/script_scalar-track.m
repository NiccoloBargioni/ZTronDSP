% Scalar track: 6 frames
times = [0.5 0.51066666666666671 0.52133333333333332 0.53200000000000003 0.54266666666666663 0.55333333333333334];
values = [216.660629 217.8909 230.827377 217.9142 213.18869 216.450089];
confidence = [1 0.875 0 0.5 1 0.25];
subplot(2, 1, 1);
plot(times, values);
xlabel('time (s)');
ylabel('value');
title('Scalar track');
grid on;
subplot(2, 1, 2);
plot(times, confidence);
xlabel('time (s)');
ylabel('confidence');
grid on;
