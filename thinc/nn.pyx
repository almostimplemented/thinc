cimport numpy as np
cimport cython
import numpy

from cymem.cymem cimport Pool

from .typedefs cimport weight_t, atom_t

from libc.string cimport memcpy
from libc.math cimport isnan


@cython.cdivision(True)
cdef void Param_asgd(Param* self, float* grad, int t, float eta, float mu) except *:
    cdef int i
    cdef float alpha = (1 / t)
    alpha = alpha if alpha >= 0.001 else 0.001
    alpha = alpha if alpha < 0.9 else 0.9

    for i in range(self.length):
        self.step[i] = (mu * self.step[i]) - grad[i]
        self.curr[i] += (eta * self.step[i])
        if t < 1000:
            self.avg[i] = self.curr[i]
        else:
            self.avg[i] = ((1 - alpha) * self.avg[i]) + (alpha * self.curr[i])

 
cdef Param Param_init(Pool mem, int length, initializer) except *:
    cdef Param param
    param.curr = <float*>mem.alloc(length, sizeof(float))
    param.avg = <float*>mem.alloc(length, sizeof(float))
    param.step = <float*>mem.alloc(length, sizeof(float))
    param.update = Param_asgd
    param.length = length

    # Draw random values from the initializer. avg and curr should have the same
    # values. Step is initialized to 0s
    for i in range(length):
        param.curr[i] = initializer()
        param.avg[i] = param.curr[i]
    return param


cdef class EmbeddingTable:
    def __init__(self, n_cols, initializer):
        self.mem = Pool()
        self.initializer = initializer
        self.n_cols = n_cols
        self.table = PreshMap()

    cdef Param* get(self, atom_t key) except NULL:
        param = <Param*>self.table.get(key)
        if param is NULL:
            param = <Param*>self.mem.alloc(1, sizeof(Param))
            param[0] = Param_init(self.mem, self.n_cols, self.initializer)
            self.table.set(key, param)
        return param


cdef class InputLayer:
    '''An input layer to an NN.'''
    def __init__(self, input_structure, initializer):
        self.mem = Pool()
        self.length = 0
        self.tables = []
        self.indices = []
        for i, (n_cols, fields) in enumerate(input_structure):
            self.tables.append(EmbeddingTable(n_cols, initializer))
            self.indices.append(fields)
            self.length += len(fields) * n_cols

    def __len__(self):
        return self.length
    
    @cython.boundscheck(False)
    def fill(self, float[:] output, atom_t[:] context, use_avg=False):
        cdef int i, j, idx, c
        cdef EmbeddingTable table
        cdef const Param* param
        c = 0
        for table in self.tables:
            for idx in self.indices[i]:
                param = table.get(context[idx])
                if use_avg:
                    memcpy(&output[c], param.avg, param.length * sizeof(float))
                else:
                    memcpy(&output[c], param.curr, param.length * sizeof(float))
                c += param.length

    @cython.boundscheck(False)
    def update(self, float[:] gradient, atom_t[:] context, t, eta, mu):
        cdef int i, j, idx, c
        cdef EmbeddingTable table
        cdef Param* param
        c = 0
        for table in self.tables:
            for idx in self.indices[i]:
                param = table.get(context[idx])
                param.update(param, &gradient[c], t, eta, mu)
                c += param.length