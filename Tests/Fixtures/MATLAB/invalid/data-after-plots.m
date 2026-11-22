% expect: y is assigned after the plots began (line 3): MAT-2 defines the data, then plots it
x = [1 2 3];
plot(x, x);
xlabel('time (s)');
ylabel('value');
y = x;
