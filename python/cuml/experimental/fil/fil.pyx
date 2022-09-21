import pathlib
import treelite.sklearn
from libcpp cimport bool
from libc.stdint cimport uint32_t, uintptr_t

from cuml.common.base import Base
from cuml.common.mixins import CMajorInputTagMixin
from cuml.experimental.kayak.cuda_stream cimport cuda_stream as kayak_stream_t
from cuml.experimental.kayak.device_type cimport device_type as kayak_device_t
from cuml.experimental.kayak.handle cimport handle_t as kayak_handle_t
from cuml.experimental.kayak.optional cimport optional, nullopt
from raft.common.handle cimport handle_t as raft_handle_t

cdef extern from "treelite/c_api.h":
    ctypedef void* ModelHandle
    cdef int TreeliteLoadXGBoostModel(const char* filename,
                                      ModelHandle* out) except +
    cdef int TreeliteLoadXGBoostJSON(const char* filename,
                                     ModelHandle* out) except +
    cdef int TreeliteFreeModel(ModelHandle handle) except +
    cdef int TreeliteQueryNumTree(ModelHandle handle, size_t* out) except +
    cdef int TreeliteQueryNumFeature(ModelHandle handle, size_t* out) except +
    cdef int TreeliteQueryNumClass(ModelHandle handle, size_t* out) except +
    cdef int TreeliteLoadLightGBMModel(const char* filename,
                                       ModelHandle* out) except +
    cdef int TreeliteSerializeModel(const char* filename,
                                    ModelHandle handle) except +
    cdef int TreeliteDeserializeModel(const char* filename,
                                      ModelHandle handle) except +
    cdef const char* TreeliteGetLastError()


cdef class TreeliteModel():
    """
    Wrapper for Treelite-loaded forest

    .. note:: This is only used for loading saved models into ForestInference,
    it does not actually perform inference. Users typically do
    not need to access TreeliteModel instances directly.

    Attributes
    ----------

    handle : ModelHandle
        Opaque pointer to Treelite model
    """
    cpdef ModelHandle handle
    cpdef bool owns_handle

    def __cinit__(self, owns_handle=True):
        """If owns_handle is True, free the handle's model in destructor.
        Set this to False if another owner will free the model."""
        self.handle = <ModelHandle>NULL
        self.owns_handle = owns_handle

    cdef set_handle(self, ModelHandle new_handle):
        self.handle = new_handle

    cdef ModelHandle get_handle(self):
        return self.handle

    @property
    def handle(self):
        return <uintptr_t>(self.handle)

    def __dealloc__(self):
        if self.handle != NULL and self.owns_handle:
            TreeliteFreeModel(self.handle)

    @property
    def num_trees(self):
        assert self.handle != NULL
        cdef size_t out
        TreeliteQueryNumTree(self.handle, &out)
        return out

    @property
    def num_features(self):
        assert self.handle != NULL
        cdef size_t out
        TreeliteQueryNumFeature(self.handle, &out)
        return out

    @staticmethod
    def free_treelite_model(model_handle):
        cdef uintptr_t model_ptr = <uintptr_t>model_handle
        TreeliteFreeModel(<ModelHandle> model_ptr)

    @staticmethod
    def from_filename(filename, model_type="xgboost"):
        """
        Returns a TreeliteModel object loaded from `filename`

        Parameters
        ----------
        filename : string
            Path to treelite model file to load

        model_type : string
            Type of model: 'xgboost', 'xgboost_json', or 'lightgbm'
        """
        filename_bytes = filename.encode("UTF-8")
        cdef ModelHandle handle

        if model_type == "xgboost":
            res = TreeliteLoadXGBoostModel(filename_bytes, &handle)
        elif model_type == "xgboost_json":
            res = TreeliteLoadXGBoostJSON(filename_bytes, &handle)
        elif model_type == "lightgbm":
            res = TreeliteLoadLightGBMModel(filename_bytes, &handle)
        elif model_type == "treelite_checkpoint":
            res = TreeliteDeserializeModel(filename_bytes, &handle)
        else:
            raise ValueError("Unknown model type %s" % model_type)

        if res < 0:
            err = TreeliteGetLastError()
            raise RuntimeError("Failed to load %s (%s)" % (filename, err))
        model = TreeliteModel()
        model.set_handle(handle)
        return model

    def to_treelite_checkpoint(self, filename):
        """
        Serialize to a Treelite binary checkpoint

        Parameters
        ----------
        filename : string
            Path to Treelite binary checkpoint
        """
        assert self.handle != NULL
        filename_bytes = filename.encode("UTF-8")
        TreeliteSerializeModel(filename_bytes, self.handle)

    @staticmethod
    def from_treelite_model_handle(treelite_handle,
                                   take_handle_ownership=False):
        cdef ModelHandle handle = <ModelHandle> <size_t> treelite_handle
        model = TreeliteModel(owns_handle=take_handle_ownership)
        model.set_handle(handle)
        return model


cdef extern from "cuml/experimental/fil/forest_model.hpp" namespace "ML::experimental::fil":
    cdef cppclass forest_model:
        void predict[io_t](
            const kayak_handle_t&,
            io_t*,
            io_t*,
            size_t,
            optional[uint32_t]
        )

        bool is_double_precision()

cdef extern from "cuml/experimental/fil/treelite_importer.hpp" namespace "ML::experimental::fil":
    forest_model import_from_treelite_handle(
        ModelHandle,
        uint32_t,
        optional[bool],
        kayak_device_t,
        int,
        kayak_stream_t
    )

cdef class ForestInference_impl():
    cdef forest_model model
    cdef kayak_handle_t kayak_handle
    cdef object raft_handle

    def __cinit__(
            self,
            raft_handle,
            tl_model,
            *,
            align_bytes=0,
            use_double_precision=None,
            mem_type='gpu',
            device_id=0):
        # Store reference to RAFT handle to control lifetime, since kayak
        # handle keeps a pointer to it
        self.raft_handle = raft_handle
        self.kayak_handle = kayak_handle_t(
            <raft_handle_t*><size_t>self.raft_handle.getHandle()
        )
        cdef optional[bool] use_double_precision_c
        if use_double_precision is None:
            use_double_precision_c = nullopt
        else:
            use_double_precision_c = use_double_precision

        try:
            model_handle = tl_model.handle
        except AttributeError:
            model_handle = tl_model

        cdef kayak_device_t dev_type
        if mem_type == 'cpu':
            dev_type = kayak_device_t.cpu
        else:
            dev_type = kayak_device_t.gpu

        self.model = import_from_treelite_handle(
            <ModelHandle><uintptr_t>model_handle,
            align_bytes,
            use_double_precision_c,
            dev_type,
            device_id,
            self.kayak_handle.get_next_usable_stream()
        )

    def get_dtype():
        return [np.float32, np.float64][model.is_double_precision()]

    def predict(self, X, *, preds=None, chunk_size=None):

        model_dtype = get_dtype()
        in_arr, n_rows, n_cols, dtype = input_to_cuml_array(
            X,
            order='C',
            convert_to_dtype=model_dtype,
            check_dtype=model_dtype
        )
        in_ptr = in_arr.ptr


class ForestInference(Base, CMajorInputTagMixin):
    """
    ForestInference provides accelerated inference for forest models on both
    CPU and GPU.
    """

    def __init__(
            self,
            *,
            treelite_model=None,
            handle=None,
            output_type=None,
            verbose=False,
            align_bytes=None,
            precision='single',
            mem_type='gpu',
            device_id=0):
        super().__init__(
            handle=handle, verbose=verbose, output_type=output_type
        )
        if treelite_model is not None:
            self._impl = ForestInference_impl(self.handle, treelite_model)
        else:
            self._impl = None

    @classmethod
    def from_file(
            cls,
            path,
            *,
            handle=None,
            output_type=None,
            verbose=False,
            model_type=None,
            align_bytes=None,
            precision='single',
            mem_type='gpu',
            device_id=0):
        if model_type is None:
            extension = pathlib.Path(path).suffix
            if extension == '.json':
                model_type = 'xgboost_json'
            elif extension == '.model':
                model_type = 'xgboost'
            elif extension == '.txt':
                model_type = 'lightgbm'
            else:
                model_type = 'treelite_checkpoint'
        tl_model = TreeliteModel.from_filename(path, model_type)
        return cls(
            treelite_model=tl_model,
            handle=handle,
            output_type=output_type,
            verbose=verbose,
            align_bytes=align_bytes,
            precision=precision,
            mem_type=mem_type,
            device_id=device_id
        )

    @classmethod
    def from_sklearn(
            cls,
            skl_model,
            *,
            handle=None,
            output_type=None,
            verbose=False,
            model_type=None,
            align_bytes=None,
            precision='single',
            mem_type='gpu',
            device_id=0):
        tl_model = treelite.sklearn.import_model(skl_model)
        return cls(
            treelite_model=tl_model,
            handle=handle,
            output_type=output_type,
            verbose=verbose,
            align_bytes=align_bytes,
            precision=precision,
            mem_type=mem_type,
            device_id=device_id
        )

    def predict(self, X, *, preds=None, chunk_size=None):
        return self._impl.predict(X, preds=preds, chunk_size=chunk_size)