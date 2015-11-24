from os import path
from cpython.mem cimport PyMem_Free, PyMem_Malloc
from libc.stdio cimport FILE, fopen, fclose, fread, fwrite, feof, fseek
from libc.errno cimport errno
from libc.string cimport memcpy
from libc.string cimport memset

from libc.stdlib cimport qsort
from libc.stdint cimport int32_t

from preshed.maps cimport PreshMap, MapStruct, map_get
from .sparse cimport SparseArray

from .api cimport Example, arg_max, arg_max_if_zero, arg_max_if_true
from .structs cimport SparseArrayC
from .typedefs cimport class_t, count_t
from .matrix cimport Matrix


cdef class Model:
    def __init__(self):
        raise NotImplementedError

    def __call__(self, Example eg):
        self.set_scores(eg.c.scores, eg.c.features, eg.c.nr_feat)
        eg.c.guess = arg_max_if_true(eg.c.scores, eg.c.is_valid, eg.c.nr_class)


cdef class LinearModel(Model):
    '''A linear model for online supervised classification.
    Expected use is via Cython --- the Python API is impoverished and inefficient.

    Emphasis is on efficiency for multi-class classification, where the number
    of classes is in the dozens or low hundreds.
    '''
    def __init__(self):
        self.weights = PreshMap()
        self.mem = Pool()

    def __dealloc__(self):
        cdef size_t feat_addr
        # Use 'raw' memory management, instead of cymem.Pool, for weights.
        # The memory overhead of cymem becomes significant here.
        if self.weights is not None:
            for feat_addr in self.weights.values():
                if feat_addr != 0:
                    PyMem_Free(<SparseArrayC*>feat_addr)

    cdef void set_scores(self, weight_t* scores, const FeatureC* feats, int nr_feat) nogil:
        # This is the main bottle-neck of spaCy --- where we spend all our time.
        # Typical sizes for the dependency parser model:
        # * weights_table: ~9 million entries
        # * n_feats: ~200
        # * scores: ~80 classes
        # 
        # I think the bottle-neck is actually reading the weights from main memory.

        cdef const MapStruct* weights_table = self.weights.c_map
 
        cdef int i, j
        cdef FeatureC feat
        for i in range(nr_feat):
            feat = feats[i]
            class_weights = <const SparseArrayC*>map_get(weights_table, feat.key)
            if class_weights != NULL:
                j = 0
                while class_weights[j].key >= 0:
                    scores[class_weights[j].key] += class_weights[j].val * feat.val
                    j += 1
    
    def dump(self, nr_class, loc):
        cdef:
            feat_t key
            size_t i
            size_t feat_addr

        cdef _Writer writer = _Writer(loc, nr_class)
        for i, (key, feat_addr) in enumerate(self.weights.items()):
            if feat_addr != 0:
                writer.write(key, <SparseArrayC*>feat_addr)
        writer.close()

    def load(self, loc):
        cdef feat_t feat_id
        cdef SparseArrayC* feature
        cdef _Reader reader = _Reader(loc)
        while reader.read(self.mem, &feat_id, &feature):
            self.weights.set(feat_id, feature)
        return reader._nr_class


cdef class MultiLayerPerceptron(Model):
    def __init__(self, width, depth):
        Model.__init__(self)
        self.width = width
        self.depth = depth

    def __dealloc__(self):
        pass

    def __call__(self, Example eg):
        self.set_scores(eg.c.scores, eg.c.features, eg.c.nr_feat)
        eg.c.guess = arg_max_if_true(eg.c.scores, eg.c.is_valid, eg.c.nr_class)

    cdef void set_scores(self, weight_t* activity, const FeatureC* feats, int nr_feat) nogil:
        # The start of 'activity' is the class scores, but the array holds the
        # activations from each level, top down, i.e. the activity from the 
        # embeddings is at the end of the activity buffer, preceded by the activity
        # from the first hidden layer, etc.
        
        input_ = get_embed(activity, self.shape) # TODO
        cdef int i
        for i in range(nr_feat):
            embed = <const EmbedC*>self.weights.get(feats[i].key)
            if embed is not NULL:
                Vector.iaddC(&input_[embed.offset], embed.data, embed.length,
                             feats[i].val)

        weights = <const weight_t*>self.weights.get(1)
        for i in range(self.depth):
            signal = get_activity(activity, i) # TODO
            layer = get_layer(weights, i)      # TODO

            LinAlg.dotC(signal, layer.W, input_, layer.b)

            layer.activate(signal)
            input_ = signal

    cdef void backprop(self, weight_t* grads, const weight_t* activity,
                       const int* costs) except *:
        # Set delta loss
        set_delta_loss(deltas, scores, costs, self.nr_class)

        weights = <const weight_t*>self.weights.get(1)

        for i in range(self.depth, -1, -1):
            delta = get_layer_delta(deltas, i)
            signal = get_layer_signal(signals, i)
            grad = get_layer_grad(grads, i)
            layer = get_layer(weights, i)

            LinAlg.iadd(gradient.b, delta, layer.nr_out)
            LinAlg.iadd_outer(gradient.W, delta, signal)
            if i != 0:
                layer.d_activate(delta, signal)
                LinAlg.mul_T(delta, layer.W, signal, layer.nr_wide, layer.nr_out)



cdef class _Writer:
    cdef FILE* _fp
    cdef class_t _nr_class
    cdef count_t _freq_thresh

    def __init__(self, object loc, nr_class):
        if path.exists(loc):
            assert not path.isdir(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        self._fp = fopen(<char*>bytes_loc, 'wb')
        assert self._fp != NULL
        fseek(self._fp, 0, 0)
        self._nr_class = nr_class
        _write(&self._nr_class, sizeof(self._nr_class), 1, self._fp)

    def close(self):
        cdef size_t status = fclose(self._fp)
        assert status == 0

    cdef int write(self, feat_t feat_id, SparseArrayC* feat) except -1:
        if feat == NULL:
            return 0
        
        _write(&feat_id, sizeof(feat_id), 1, self._fp)
        
        cdef int i = 0
        while feat[i].key >= 0:
            i += 1
        cdef int32_t length = i
        
        _write(&length, sizeof(length), 1, self._fp)
        
        qsort(feat, length, sizeof(SparseArrayC), SparseArray.cmp)
        
        for i in range(length):
            _write(&feat[i].key, sizeof(feat[i].key), 1, self._fp)
            _write(&feat[i].val, sizeof(feat[i].val), 1, self._fp)


cdef int _write(void* value, size_t size, int n, FILE* fp) except -1:
    status = fwrite(value, size, 1, fp)
    assert status == 1, status


cdef class _Reader:
    cdef FILE* _fp
    cdef class_t _nr_class
    cdef count_t _freq_thresh

    def __init__(self, loc):
        assert path.exists(loc)
        assert not path.isdir(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        self._fp = fopen(<char*>bytes_loc, 'rb')
        assert self._fp != NULL
        status = fseek(self._fp, 0, 0)
        status = fread(&self._nr_class, sizeof(self._nr_class), 1, self._fp)

    def __dealloc__(self):
        fclose(self._fp)

    cdef int read(self, Pool mem, feat_t* out_id, SparseArrayC** out_feat) except -1:
        cdef feat_t feat_id
        cdef int32_t length

        status = fread(&feat_id, sizeof(feat_t), 1, self._fp)
        if status == 0:
            return 0
        assert status

        status = fread(&length, sizeof(length), 1, self._fp)
        assert status
        
        feat = <SparseArrayC*>PyMem_Malloc((length + 1) * sizeof(SparseArrayC))
        
        cdef int i
        for i in range(length):
            status = fread(&feat[i].key, sizeof(feat[i].key), 1, self._fp)
            assert status
            status = fread(&feat[i].val, sizeof(feat[i].val), 1, self._fp)
            assert status

        # Trust We allocated correctly above
        feat[length].key = -2 # Indicates end of memory region
        feat[length].val = 0


        # Copy into the output variables
        out_feat[0] = feat
        out_id[0] = feat_id
        # Signal whether to continue reading, to the outer loop
        if feof(self._fp):
            return 0
        else:
            return 1
