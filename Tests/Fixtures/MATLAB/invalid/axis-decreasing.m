% expect: axis: each pair of limits increases (1 0 0 1)
x = [1 2 3];
plot(x, x);
xlabel('time (s)');
ylabel('value');
axis([1 0 0 1]);
