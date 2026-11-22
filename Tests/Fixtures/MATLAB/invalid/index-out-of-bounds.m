% expect: x: the index 4 is out of bounds (the size is 3)
% octave: out of bound 3 (dimensions are 1x3)
x = [1 2 3];
y = x(4);
