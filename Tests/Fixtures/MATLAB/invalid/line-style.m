% expect: 'r---' is not a line style
x = [1 2 3];
plot(x, x, 'r---');
xlabel('time (s)');
ylabel('value');
