% expect: plot: x holds the complex value 1+1i
z = [1+1i 2];
plot(z, z);
xlabel('real part');
ylabel('imaginary part');
