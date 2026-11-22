% expect: t is used before it is defined (column 6)
% octave: 't' undefined
x = [1 2 3];
plot(t, x);
xlabel('time (s)');
ylabel('value');
t = [0 1 2];
