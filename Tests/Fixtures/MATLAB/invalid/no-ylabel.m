% expect: subplot(1, 1, 1) shows data and has no ylabel (MAT-2: axis labels and units)
x = [1 2 3];
subplot(1, 1, 1);
plot(x, x);
xlabel('time (s)');
