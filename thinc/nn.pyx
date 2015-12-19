from __future__ import print_function
cimport cython
from libc.stdint cimport int32_t
from libc.string cimport memset, memcpy
from libc.math cimport sqrt as c_sqrt

from cymem.cymem cimport Pool, Address
from preshed.maps cimport PreshMap
import numpy

from .typedefs cimport weight_t, atom_t, feat_t
from .blas cimport VecVec


cdef class NeuralNet:
    def __init__(self, widths, weight_t eta=0.005, weight_t epsilon=1e-6, weight_t rho=1e-4):
        self.mem = Pool()
        self.c.eta = eta
        self.c.eps = epsilon
        self.c.rho = rho

        self.c.nr_layer = len(widths)
        self.c.widths = <int*>self.mem.alloc(self.c.nr_layer, sizeof(self.c.widths[0]))
        cdef int i
        for i, width in enumerate(widths):
            self.c.widths[i] = width
        self.c.nr_weight = 0
        for i in range(self.c.nr_layer-1):
            self.c.nr_weight += self.c.widths[i+1] * self.c.widths[i] + self.c.widths[i+1]
        self.c.weights = <weight_t*>self.mem.alloc(self.c.nr_weight, sizeof(self.c.weights[0]))
        self.c.support = <weight_t*>self.mem.alloc(self.c.nr_weight, sizeof(self.c.weights[0]))

        cdef int nr_out, nr_wide, nr_weight
        cdef weight_t* W = self.c.weights
        for i in range(self.c.nr_layer-2): # Don't init softmax weights
            nr_out = self.c.widths[i+1]
            nr_wide = self.c.widths[i]
            std = numpy.sqrt(2.0) * numpy.sqrt(1.0 / nr_wide)
            init_weights = numpy.random.normal(loc=0.0, scale=std, size=(nr_out * nr_wide))
            for j in range(nr_out * nr_wide):
                W[j] = init_weights[j]
            W += nr_out * nr_wide
            for j in range(nr_out):
                W[j] = 0.2
            W += nr_out
    
    property weights:
        def __get__(self):
            return [self.c.weights[i] for i in range(self.c.nr_weight)]
        def __set__(self, weights):
            cdef int i
            cdef weight_t weight
            for i, weight in enumerate(weights):
                self.c.weights[i] = weight
    property support:
        def __get__(self):
            return [self.c.support[i] for i in range(self.nr_weight)]
        def __set__(self, weights):
            for i, weight in enumerate(weights):
                self.c.support[i] = weight
    property widths:
        def __get__(self):
            return tuple([self.c.widths[i] for i in range(self.c.nr_layer)])
    property nr_layer:
        def __get__(self): return self.c.nr_layer
    property nr_weight:
        def __get__(self): return self.c.nr_weight
    property nr_out:
        def __get__(self):
            return self.c.widths[self.c.nr_layer-1]
    property nr_in:
        def __get__(self):
            return self.c.widths[0]
    property eta:
        def __get__(self):
            return self.c.eta
        def __set__(self, eta):
            self.c.eta = eta
    property rho:
        def __get__(self):
            return self.c.rho
        def __set__(self, rho):
            self.c.rho = rho
    property eps:
        def __get__(self):
            return self.c.eps
        def __set__(self, eps):
            self.c.eps = eps
    
    def __call__(self, input_):
        if len(input_) != self.nr_in:
            raise ValueError("Expected %d length input. Got %s" % (self.nr_in, input_))
        cdef Pool mem = Pool()
        fwd_state = <weight_t**>mem.alloc(self.c.nr_layer, sizeof(void*))
        for i, width in enumerate(self.widths):
            fwd_state[i] = <weight_t*>mem.alloc(width, sizeof(weight_t))

        cdef weight_t value
        for i, value in enumerate(input_):
            fwd_state[0][i] = value
        NeuralNet.forward( # Implemented in nn.pxd
            fwd_state,
            self.c.weights,
            self.c.widths,
            self.c.nr_layer
        )
        return [fwd_state[self.nr_layer-1][i] for i in range(self.nr_out)]

    def train(self, batch):
        cdef Pool mem = Pool()
        fwd_state = <weight_t**>mem.alloc(self.c.nr_layer, sizeof(void*))
        bwd_state = <weight_t**>mem.alloc(self.c.nr_layer, sizeof(void*))
        cdef int i
        for i, width in enumerate(self.widths):
            fwd_state[i] = <weight_t*>mem.alloc(width, sizeof(fwd_state[0][0]))
            bwd_state[i] = <weight_t*>mem.alloc(width, sizeof(bwd_state[0][0]))
        gradient = <weight_t*>mem.alloc(self.c.nr_weight, sizeof(weight_t))

        cdef weight_t[:] input_
        cdef weight_t[:] costs
        cdef weight_t loss = 0
        for input_, costs in batch:
            # Wipe the fwd_state and bwd_state buffers between examples
            for i in range(self.c.nr_layer):
                memset(fwd_state[i], 0, self.c.widths[i] * sizeof(weight_t))
                memset(bwd_state[i], 0, self.c.widths[i] * sizeof(weight_t))
            for i, value in enumerate(input_):
                fwd_state[0][i] = value
            # These functions are implemented in nn.pxd
            # We write the output variable inline with the declaration,
            # with the arguments trailing.
            NeuralNet.forward(fwd_state,
                self.c.weights,
                self.c.widths,
                self.c.nr_layer
            )
            Softmax.delta_log_loss(bwd_state[self.c.nr_layer-1],
                &costs[0],
                fwd_state[self.c.nr_layer-1],
                self.c.widths[self.c.nr_layer-1]
            )
            NeuralNet.backward(bwd_state,
                fwd_state,
                self.c.weights + self.c.nr_weight,
                self.c.widths,
                self.c.nr_layer
            )
            NeuralNet.set_gradients(gradient,
                bwd_state,
                fwd_state,
                self.c.widths,
                self.c.nr_layer
            )
            for i in range(self.nr_out):
                if costs[i] != 0:
                    loss += fwd_state[self.c.nr_layer - 1][i]

        # L2 regularization
        if self.c.rho != 0:
            VecVec.add_i(gradient,
                self.c.weights,
                self.c.rho,
                self.c.nr_weight
            )
       # This writes to three variables
        Adagrad.update(self.c.weights, gradient, self.c.support,
            self.c.nr_weight,
            self.c.eta,
            self.c.eps
        )
        return loss
