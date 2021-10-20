import numpy as np # type: ignore
import pandas as pd # type: ignore
import struct
from typing import cast, Iterable, Optional, Union
from typeguard import typechecked
from arkouda.client import generic_msg
from arkouda.dtypes import structDtypeCodes, NUMBER_FORMAT_STRINGS, float64, int64, \
     DTypes, isSupportedInt, isSupportedNumber, NumericDTypes, SeriesDTypes
from arkouda.dtypes import dtype as akdtype
from arkouda.pdarrayclass import pdarray, create_pdarray
from arkouda.strings import Strings, SArrays
from arkouda.graph import GraphD, GraphDW,GraphUD,GraphUDW

__all__ = ["array", "zeros", "ones", "zeros_like", "ones_like", 
           "arange", "linspace", "randint", "uniform", "standard_normal",
           "random_strings_uniform", "random_strings_lognormal", 
           "from_series", "suffix_array","lcp_array","suffix_array_file",
           "rmat_gen","graph_bfs","graph_file_read", "graph_triangle_edge", "graph_triangle",
           "KTruss", 
           "stream_file_read","stream_tri_cnt","streamPL_tri_cnt",
           "streamHead_tri_cnt","streamMid_tri_cnt","streamTail_tri_cnt"]

@typechecked
def from_series(series : pd.Series, 
                    dtype : Optional[Union[type,str]]=None) -> Union[pdarray,Strings]:
    """
    Converts a Pandas Series to an Arkouda pdarray or Strings object. If
    dtype is None, the dtype is inferred from the Pandas Series. Otherwise,
    the dtype parameter is set if the dtype of the Pandas Series is to be 
    overridden or is  unknown (for example, in situations where the Series 
    dtype is object).
    
    Parameters
    ----------
    series : Pandas Series
        The Pandas Series with a dtype of bool, float64, int64, or string
    dtype : Optional[type]
        The valid dtype types are np.bool, np.float64, np.int64, and np.str

    Returns
    -------
    Union[pdarray,Strings]
    
    Raises
    ------
    TypeError
        Raised if series is not a Pandas Series object
    ValueError
        Raised if the Series dtype is not bool, float64, int64, string, datetime, or timedelta

    Examples
    --------
    >>> ak.from_series(pd.Series(np.random.randint(0,10,5)))
    array([9, 0, 4, 7, 9])

    >>> ak.from_series(pd.Series(['1', '2', '3', '4', '5']),dtype=np.int64)
    array([1, 2, 3, 4, 5])

    >>> ak.from_series(pd.Series(np.random.uniform(low=0.0,high=1.0,size=3)))
    array([0.57600036956445599, 0.41619265571741659, 0.6615356693784662])

    >>> ak.from_series(pd.Series(['0.57600036956445599', '0.41619265571741659',
                       '0.6615356693784662']), dtype=np.float64)
    array([0.57600036956445599, 0.41619265571741659, 0.6615356693784662])

    >>> ak.from_series(pd.Series(np.random.choice([True, False],size=5)))
    array([True, False, True, True, True])

    >>> ak.from_series(pd.Series(['True', 'False', 'False', 'True', 'True']), dtype=np.bool)
    array([True, True, True, True, True])

    >>> ak.from_series(pd.Series(['a', 'b', 'c', 'd', 'e'], dtype="string"))
    array(['a', 'b', 'c', 'd', 'e'])

    >>> ak.from_series(pd.Series(['a', 'b', 'c', 'd', 'e']),dtype=np.str)
    array(['a', 'b', 'c', 'd', 'e'])

    >>> ak.from_series(pd.Series(pd.to_datetime(['1/1/2018', np.datetime64('2018-01-01')])))
    array([1514764800000000000, 1514764800000000000])  
    
    Notes
    -----
    The supported datatypes are bool, float64, int64, string, and datetime64[ns]. The
    data type is either inferred from the the Series or is set via the dtype parameter. 
    
    Series of datetime or timedelta are converted to Arkouda arrays of dtype int64 (nanoseconds)
    """ 
    if not dtype:   
        dt = series.dtype.name
    else:
        dt = str(dtype)
    try:
        n_array = series.to_numpy(dtype=SeriesDTypes[dt])
    except KeyError:
        raise ValueError(('dtype {} is unsupported. Supported dtypes are bool, ' +
                          'float64, int64, string, datetime64[ns], and timedelta64[ns]').format(dt))
    return array(n_array)

def array(a : Union[pdarray,np.ndarray, Iterable]) -> Union[pdarray, Strings]:
    """
    Convert a Python or Numpy Iterable to a pdarray or Strings object, sending 
    the corresponding data to the arkouda server. 

    Parameters
    ----------
    a : Union[pdarray, np.ndarray]
        Rank-1 array of a supported dtype

    Returns
    -------
    pdarray or Strings
        A pdarray instance stored on arkouda server or Strings instance, which
        is composed of two pdarrays stored on arkouda server
        
    Raises
    ------
    TypeError
        Raised if a is not a pdarray, np.ndarray, or Python Iterable such as a
        list, array, tuple, or deque
    RuntimeError
        Raised if a is not one-dimensional, nbytes > maxTransferBytes, a.dtype is
        not supported (not in DTypes), or if the product of a size and
        a.itemsize > maxTransferBytes
    ValueError
        Raised if the returned message is malformed or does not contain the fields
        required to generate the array.

    See Also
    --------
    pdarray.to_ndarray

    Notes
    -----
    The number of bytes in the input array cannot exceed `arkouda.maxTransferBytes`,
    otherwise a RuntimeError will be raised. This is to protect the user
    from overwhelming the connection between the Python client and the arkouda
    server, under the assumption that it is a low-bandwidth connection. The user
    may override this limit by setting ak.maxTransferBytes to a larger value, 
    but should proceed with caution.
    
    If the pdrray or ndarray is of type U, this method is called twice recursively 
    to create the Strings object and the two corresponding pdarrays for string 
    bytes and offsets, respectively.

    Examples
    --------
    >>> ak.array(np.arange(1,10))
    array([1, 2, 3, 4, 5, 6, 7, 8, 9])
    
    >>> ak.array(range(1,10))
    array([1, 2, 3, 4, 5, 6, 7, 8, 9])
   
    >>> strings = ak.array(['string {}'.format(i) for i in range(0,5)])
    >>> type(strings)
    <class 'arkouda.strings.Strings'>  
    """
    # If a is already a pdarray, do nothing
    if isinstance(a, pdarray):
        return a
    from arkouda.client import maxTransferBytes
    # If a is not already a numpy.ndarray, convert it
    if not isinstance(a, np.ndarray):
        try:
            a = np.array(a)
        except:
            raise TypeError(('a must be a pdarray, np.ndarray, or convertible to' +
                            ' a numpy array'))
    # Only rank 1 arrays currently supported
    if a.ndim != 1:
        raise RuntimeError("Only rank-1 pdarrays or ndarrays supported")
    # Check if array of strings
    if a.dtype.kind == 'U' or  'U' in a.dtype.kind:
        encoded = np.array([elem.encode() for elem in a])
        # Length of each string, plus null byte terminator
        lengths = np.array([len(elem) for elem in encoded]) + 1
        # Compute zero-up segment offsets
        offsets = np.cumsum(lengths) - lengths
        # Allocate and fill bytes array with string segments
        nbytes = offsets[-1] + lengths[-1]
        if nbytes > maxTransferBytes:
            raise RuntimeError(("Creating pdarray would require transferring {} bytes," +
                                " which exceeds allowed transfer size. Increase " +
                                "ak.maxTransferBytes to force.").format(nbytes))
        values = np.zeros(nbytes, dtype=np.uint8)
        for s, o in zip(encoded, offsets):
            for i, b in enumerate(s):
                values[o+i] = b
        # Recurse to create pdarrays for offsets and values, then return Strings object
        return Strings(cast(pdarray, array(offsets)), cast(pdarray, array(values)))
    # If not strings, then check that dtype is supported in arkouda
    if a.dtype.name not in DTypes:
        raise RuntimeError("Unhandled dtype {}".format(a.dtype))
    # Do not allow arrays that are too large
    size = a.size
    if (size * a.itemsize) > maxTransferBytes:
        raise RuntimeError(("Array exceeds allowed transfer size. Increase " +
                            "ak.maxTransferBytes to allow"))
    # Pack binary array data into a bytes object with a command header
    # including the dtype and size
    fmt = ">{:n}{}".format(size, structDtypeCodes[a.dtype.name])
    req_msg = "{} {:n} ".\
                    format(a.dtype.name, size).encode() + struct.pack(fmt, *a)
    repMsg = generic_msg(cmd='array', args=req_msg, send_bytes=True)
    return create_pdarray(repMsg)

def zeros(size : Union[int,np.int64], dtype : type=np.float64) -> pdarray:
    """
    Create a pdarray filled with zeros.

    Parameters
    ----------
    size : Union[int,int64]
        Size of the array (only rank-1 arrays supported)
    dtype : Union[float, np.float64, int, np.int64, bool, np.bool}
        Type of resulting array, default float64

    Returns
    -------
    pdarray
        Zeros of the requested size and dtype
        
    Raises
    ------
    TypeError
        Raised if the supplied dtype is not supported or if the size
        parameter is neither an int nor a str that is parseable to an int.

    See Also
    --------
    ones, zeros_like

    Examples
    --------
    >>> ak.zeros(5, dtype=ak.int64)
    array([0, 0, 0, 0, 0])

    >>> ak.zeros(5, dtype=ak.float64)
    array([0, 0, 0, 0, 0])

    >>> ak.zeros(5, dtype=ak.bool)
    array([False, False, False, False, False])
    """
    if not np.isscalar(size):
        raise TypeError("size must be a scalar, not {}".\
                                     format(size.__class__.__name__))
    dtype = akdtype(dtype) # normalize dtype
    # check dtype for error
    if cast(np.dtype,dtype).name not in NumericDTypes:
        raise TypeError("unsupported dtype {}".format(dtype))
    repMsg = generic_msg(cmd="create", args="{} {}".format(
                                    cast(np.dtype,dtype).name, size))
    
    return create_pdarray(repMsg)

def ones(size : Union[int,np.int64], dtype : type=float64) -> pdarray:
    """
    Create a pdarray filled with ones.

    Parameters
    ----------
    size : Union[int,np.int64]
        Size of the array (only rank-1 arrays supported)
    dtype : Union[float64, int64, bool]
        Resulting array type, default float64

    Returns
    -------
    pdarray
        Ones of the requested size and dtype
        
    Raises
    ------
    TypeError
        Raised if the supplied dtype is not supported or if the size
        parameter is neither an int nor a str that is parseable to an int.

    See Also
    --------
    zeros, ones_like

    Examples
    --------
    >>> ak.ones(5, dtype=ak.int64)
    array([1, 1, 1, 1, 1])

    >>> ak.ones(5, dtype=ak.float64)
    array([1, 1, 1, 1, 1])

    >>> ak.ones(5, dtype=ak.bool)
    array([True, True, True, True, True])
    """
    if not np.isscalar(size):
        raise TypeError("size must be a scalar, not {}".\
                                            format(size.__class__.__name__))
    dtype = akdtype(dtype) # normalize dtype
    # check dtype for error
    if cast(np.dtype,dtype).name not in NumericDTypes:
        raise TypeError("unsupported dtype {}".format(dtype))
    repMsg = generic_msg(cmd="create", args="{} {}".format(
                                           cast(np.dtype,dtype).name, size))
    a = create_pdarray(repMsg)
    a.fill(1)
    return a

@typechecked
def zeros_like(pda : pdarray) -> pdarray:
    """
    Create a zero-filled pdarray of the same size and dtype as an existing 
    pdarray.

    Parameters
    ----------
    pda : pdarray
        Array to use for size and dtype

    Returns
    -------
    pdarray
        Equivalent to ak.zeros(pda.size, pda.dtype)
        
    Raises
    ------
    TypeError
        Raised if the pda parameter is not a pdarray.

    See Also
    --------
    zeros, ones_like

    Examples
    --------
    >>> zeros = ak.zeros(5, dtype=ak.int64)
    >>> ak.zeros_like(zeros)
    array([0, 0, 0, 0, 0])

    >>> zeros = ak.zeros(5, dtype=ak.float64)
    >>> ak.zeros_like(zeros)
    array([0, 0, 0, 0, 0])

    >>> zeros = ak.zeros(5, dtype=ak.bool)
    >>> ak.zeros_like(zeros)
    array([False, False, False, False, False])
    """
    return zeros(pda.size, pda.dtype)

@typechecked
def ones_like(pda : pdarray) -> pdarray:
    """
    Create a one-filled pdarray of the same size and dtype as an existing 
    pdarray.

    Parameters
    ----------
    pda : pdarray
        Array to use for size and dtype

    Returns
    -------
    pdarray
        Equivalent to ak.ones(pda.size, pda.dtype)
        
    Raises
    ------
    TypeError
        Raised if the pda parameter is not a pdarray.

    See Also
    --------
    ones, zeros_like
    
    Notes
    -----
    Logic for generating the pdarray is delegated to the ak.ones method.
    Accordingly, the supported dtypes match are defined by the ak.ones method.
    
    Examples
    --------
    >>> ones = ak.ones(5, dtype=ak.int64)
     >>> ak.ones_like(ones)
    array([1, 1, 1, 1, 1])

    >>> ones = ak.ones(5, dtype=ak.float64)
    >>> ak.ones_like(ones)
    array([1, 1, 1, 1, 1])

    >>> ones = ak.ones(5, dtype=ak.bool)
    >>> ak.ones_like(ones)
    array([True, True, True, True, True])
    """
    return ones(pda.size, pda.dtype)

def arange(*args) -> pdarray:
    """
    arange([start,] stop[, stride])

    Create a pdarray of consecutive integers within the interval [start, stop).
    If only one arg is given then arg is the stop parameter. If two args are
    given, then the first arg is start and second is stop. If three args are
    given, then the first arg is start, second is stop, third is stride.

    Parameters
    ----------
    start : Union[int,np.int64], optional
        Starting value (inclusive)
    stop : Union[int,np.int64]
        Stopping value (exclusive)
    stride : Union[int,np.int64], optional
        The difference between consecutive elements, the default stride is 1,
        if stride is specified then start must also be specified. 

    Returns
    -------
    pdarray, int64
        Integers from start (inclusive) to stop (exclusive) by stride
        
    Raises
    ------
    TypeError
        Raised if start, stop, or stride is not an int object
    ZeroDivisionError
        Raised if stride == 0

    See Also
    --------
    linspace, zeros, ones, randint
    
    Notes
    -----
    Negative strides result in decreasing values. Currently, only int64 
    pdarrays can be created with this method. For float64 arrays, use 
    the linspace method.

    Examples
    --------
    >>> ak.arange(0, 5, 1)
    array([0, 1, 2, 3, 4])

    >>> ak.arange(5, 0, -1)
    array([5, 4, 3, 2, 1])

    >>> ak.arange(0, 10, 2)
    array([0, 2, 4, 6, 8])
    
    >>> ak.arange(-5, -10, -1)
    array([-5, -6, -7, -8, -9])
    """
   
    #if one arg is given then arg is stop
    if len(args) == 1:
        start = 0
        stop = args[0]
        stride = 1

    #if two args are given then first arg is start and second is stop
    if len(args) == 2:
        start = args[0]
        stop = args[1]
        stride = 1

    #if three args are given then first arg is start,
    #second is stop, third is stride
    if len(args) == 3:
        start = args[0]
        stop = args[1]
        stride = args[2]

    if stride == 0:
        raise ZeroDivisionError("division by zero")

    if isSupportedInt(start) and isSupportedInt(stop) and isSupportedInt(stride):
        if stride < 0:
            stop = stop + 2
        repMsg = generic_msg(cmd='arange', args="{} {} {}".format(start, stop, stride))
        return create_pdarray(repMsg)
    else:
        raise TypeError("start,stop,stride must be type int or np.int64 {} {} {}".\
                                    format(start,stop,stride))

@typechecked
def linspace(start : Union[float,np.float64,int,np.int64], 
             stop : Union[float,np.float64,int,np.int64], length : Union[int,np.int64]) -> pdarray:
    """
    Create a pdarray of linearly-spaced floats in a closed interval.

    Parameters
    ----------
    start : Union[float,np.float64, int, np.int64]
        Start of interval (inclusive)
    stop : Union[float,np.float64, int, np.int64]
        End of interval (inclusive)
    length : Union[int,np.int64]
        Number of points

    Returns
    -------
    pdarray, float64
        Array of evenly spaced float values along the interval
        
    Raises
    ------
    TypeError
        Raised if start or stop is not a float or int or if length is not an int

    See Also
    --------
    arange
    
    Notes
    -----
    If that start is greater than stop, the pdarray values are generated
    in descending order.

    Examples
    --------
    >>> ak.linspace(0, 1, 5)
    array([0, 0.25, 0.5, 0.75, 1])

    >>> ak.linspace(start=1, stop=0, length=5)
    array([1, 0.75, 0.5, 0.25, 0])

    >>> ak.linspace(start=-5, stop=0, length=5)
    array([-5, -3.75, -2.5, -1.25, 0])
    """
    if not isSupportedNumber(start) or not isSupportedNumber(stop):
        raise TypeError('both start and stop must be an int, np.int64, float, or np.float64')
    if not isSupportedNumber(length):
        raise TypeError('length must be an int or int64')
    repMsg = generic_msg(cmd='linspace', args="{} {} {}".format(start, stop, length))
    return create_pdarray(repMsg)

@typechecked
def randint(low : Union[int,np.int64,float,np.float64], high : Union[int,np.int64,float,np.float64], 
            size : Union[int,np.int64], dtype=int64, seed : Union[int,np.int64]=None) -> pdarray:
    """
    Generate a pdarray of randomized int, float, or bool values in a 
    specified range bounded by the low and high parameters.

    Parameters
    ----------
    low : Union[int,np.int64,float,np.float64]
        The low value (inclusive) of the range
    high : Union[int,np.int64,float,np.float64]
        The high value (exclusive for int, inclusive for float) of the range
    size : Union[int,np.int64]
        The length of the returned array
    dtype : Union[int64, float64, bool]
        The dtype of the array
    seed : Union[int,np.int64]
        Index for where to pull the first returned value
        

    Returns
    -------
    pdarray
        Values drawn uniformly from the specified range having the desired dtype
        
    Raises
    ------
    TypeError
        Raised if dtype.name not in DTypes, size is not an int, low or high is
        not an int or float, or seed is not an int
    ValueError
        Raised if size < 0 or if high < low

    Notes
    -----
    Calling randint with dtype=float64 will result in uniform non-integral
    floating point values.

    Examples
    --------
    >>> ak.randint(0, 10, 5)
    array([5, 7, 4, 8, 3])

    >>> ak.randint(0, 1, 3, dtype=ak.float64)
    array([0.92176432277231968, 0.083130710959903542, 0.68894208386667544])

    >>> ak.randint(0, 1, 5, dtype=ak.bool)
    array([True, False, True, True, True])
    
    >>> ak.randint(1, 5, 10, seed=2)
    array([4, 3, 1, 3, 4, 4, 2, 4, 3, 2])

    >>> ak.randint(1, 5, 3, dtype=ak.float64, seed=2)
    array([2.9160772326374946, 4.353429832157099, 4.5392023718621486])
    
    >>> ak.randint(1, 5, 10, dtype=ak.bool, seed=2)
    array([False, True, True, True, True, False, True, True, True, True])
    """
    if size < 0 or high < low:
        raise ValueError("size must be > 0 and high > low")
    dtype = akdtype(dtype) # normalize dtype
    # check dtype for error
    if dtype.name not in DTypes:
        raise TypeError("unsupported dtype {}".format(dtype))
    lowstr = NUMBER_FORMAT_STRINGS[dtype.name].format(low)
    highstr = NUMBER_FORMAT_STRINGS[dtype.name].format(high)
    sizestr = NUMBER_FORMAT_STRINGS['int64'].format(size)

    repMsg = generic_msg(cmd='randint', args='{} {} {} {} {}'.\
                         format(sizestr, dtype.name, lowstr, highstr, seed))
    return create_pdarray(cast(str,repMsg))

@typechecked
def uniform(size : Union[int,np.int64], low : Union[float,np.float64]=0.0, 
            high : Union[float,np.float64]=1.0, seed: Union[None, 
                                               Union[int,np.int64]]=None) -> pdarray:
    """
    Generate a pdarray with uniformly distributed random float values 
    in a specified range.

    Parameters
    ----------
    low : Union[float,np.float64]
        The low value (inclusive) of the range, defaults to 0.0
    high : Union[float,np.float64]
        The high value (inclusive) of the range, defaults to 1.0
    size : Union[int,np.int64]
        The length of the returned array
    seed : Union[int,np.int64], optional
        Value used to initialize the random number generator

    Returns
    -------
    pdarray, float64
        Values drawn uniformly from the specified range

    Raises
    ------
    TypeError
        Raised if dtype.name not in DTypes, size is not an int, or if
        either low or high is not an int or float
    ValueError
        Raised if size < 0 or if high < low

    Notes
    -----
    The logic for uniform is delegated to the ak.randint method which 
    is invoked with a dtype of float64

    Examples
    --------
    >>> ak.uniform(3)
    array([0.92176432277231968, 0.083130710959903542, 0.68894208386667544])

    >>> ak.uniform(size=3,low=0,high=5,seed=0)
    array([0.30013431967121934, 0.47383036230759112, 1.0441791878997098])
    """
    return randint(low=low, high=high, size=size, dtype='float64', seed=seed)

@typechecked
def standard_normal(size : Union[int,np.int64], seed : Union[None, Union[int,np.int64]]=None) -> pdarray:
    """
    Draw real numbers from the standard normal distribution.

    Parameters
    ----------
    size : Union[int,np.int64]
        The number of samples to draw (size of the returned array)
    seed : Union[int,np.int64]
        Value used to initialize the random number generator
    
    Returns
    -------
    pdarray, float64
        The array of random numbers
        
    Raises
    ------
    TypeError
        Raised if size is not an int
    ValueError
        Raised if size < 0

    See Also
    --------
    randint

    Notes
    -----
    For random samples from :math:`N(\\mu, \\sigma^2)`, use:

    ``(sigma * standard_normal(size)) + mu``
    
    Examples
    --------
    >>> ak.standard_normal(3,1)
    array([-0.68586185091150265, 1.1723810583573375, 0.567584107142031])  
    """
    if size < 0:
        raise ValueError("The size parameter must be > 0")
    return create_pdarray(generic_msg(cmd='randomNormal', args='{} {}'.\
                    format(NUMBER_FORMAT_STRINGS['int64'].format(size), seed)))

@typechecked
def random_strings_uniform(minlen : Union[int,np.int64], maxlen : Union[int,np.int64], 
                        size : Union[int,np.int64], characters : str='uppercase', 
                           seed : Union[None, Union[int,np.int64]]=None) -> Strings:
    """
    Generate random strings with lengths uniformly distributed between 
    minlen and maxlen, and with characters drawn from a specified set.

    Parameters
    ----------
    minlen : Union[int,np.int64]
        The minimum allowed length of string
    maxlen : Union[int,np.int64]
        The maximum allowed length of string
    size : Union[int,np.int64]
        The number of strings to generate
    characters : (uppercase, lowercase, numeric, printable, binary)
        The set of characters to draw from
    seed :  Union[None, Union[int,np.int64]], optional
        Value used to initialize the random number generator

    Returns
    -------
    Strings
        The array of random strings
        
    Raises
    ------
    ValueError
        Raised if minlen < 0, maxlen < minlen, or size < 0

    See Also
    --------
    random_strings_lognormal, randint
    
    Examples
    --------
    >>> ak.random_strings_uniform(minlen=1, maxlen=5, seed=1, size=5)
    array(['TVKJ', 'EWAB', 'CO', 'HFMD', 'U'])
    
    >>> ak.random_strings_uniform(minlen=1, maxlen=5, seed=1, size=5, 
    ... characters='printable')
    array(['+5"f', '-P]3', '4k', '~HFF', 'F'])
    """
    if minlen < 0 or maxlen < minlen or size < 0:
        raise ValueError(("Incompatible arguments: minlen < 0, maxlen " +
                          "< minlen, or size < 0"))

    repMsg = generic_msg(cmd="randomStrings", args="{} {} {} {} {} {}".\
          format(NUMBER_FORMAT_STRINGS['int64'].format(size),
                 "uniform", characters,
                 NUMBER_FORMAT_STRINGS['int64'].format(minlen),
                 NUMBER_FORMAT_STRINGS['int64'].format(maxlen),
                 seed))
    return Strings(*(cast(str,repMsg).split('+')))

@typechecked
def random_strings_lognormal(logmean : Union[int,np.int64,float,np.float64], 
                             logstd : Union[int,np.int64,float,np.float64], 
                             size : Union[int,np.int64], characters : str='uppercase', 
                             seed : Union[None, Union[int,np.int64]]=None) -> Strings:
    """
    Generate random strings with log-normally distributed lengths and 
    with characters drawn from a specified set.

    Parameters
    ----------
    logmean : Union[int,np.int64,float,np.float64]
        The log-mean of the length distribution
    logstd :  Union[int,np.int64,float,np.float64]
        The log-standard-deviation of the length distribution
    size : Union[int,np.int64]
        The number of strings to generate
    characters : (uppercase, lowercase, numeric, printable, binary)
        The set of characters to draw from
    seed : Union[int,np.int64], optional
        Value used to initialize the random number generator

    Returns
    -------
    Strings
        The Strings object encapsulating a pdarray of random strings
    
    Raises
    ------
    TypeError
        Raised if logmean is neither a float nor a int, logstd is not a float, 
        size is not an int, or if characters is not a str
    ValueError
        Raised if logstd <= 0 or size < 0

    See Also
    --------
    random_strings_lognormal, randint

    Notes
    -----
    The lengths of the generated strings are distributed $Lognormal(\\mu, \\sigma^2)$,
    with :math:`\\mu = logmean` and :math:`\\sigma = logstd`. Thus, the strings will
    have an average length of :math:`exp(\\mu + 0.5*\\sigma^2)`, a minimum length of 
    zero, and a heavy tail towards longer strings.
    
    Examples
    --------
    >>> ak.random_strings_lognormal(2, 0.25, 5, seed=1)
    array(['TVKJTE', 'ABOCORHFM', 'LUDMMGTB', 'KWOQNPHZ', 'VSXRRL'])
    
    >>> ak.random_strings_lognormal(2, 0.25, 5, seed=1, characters='printable')
    array(['+5"fp-', ']3Q4kC~HF', '=F=`,IE!', 'DjkBa'9(', '5oZ1)='])
    """
    if not isSupportedNumber(logmean) or not isSupportedNumber(logstd):
        raise TypeError('both logmean and logstd must be an int, np.int64, float, or np.float64')
    if logstd <= 0 or size < 0:
        raise ValueError("Incompatible arguments: logstd <= 0 or size < 0")

    repMsg = generic_msg(cmd="randomStrings", args="{} {} {} {} {} {}".\
          format(NUMBER_FORMAT_STRINGS['int64'].format(size),
                 "lognormal", characters,
                 NUMBER_FORMAT_STRINGS['float64'].format(logmean),
                 NUMBER_FORMAT_STRINGS['float64'].format(logstd),
                 seed))
    return Strings(*(cast(str,repMsg).split('+')))



@typechecked
def suffix_array(strings : Strings) -> SArrays:
        """
        Return the suffix arrays of given strings. The size/shape of each suffix
	arrays is the same as the corresponding strings. 
	A simple example of suffix array is as follow. Given a string "banana$",
	all the suffixes are as follows. 
	s[0]="banana$"
	s[1]="anana$"
	s[2]="nana$"
	s[3]="ana$"
	s[4]="na$"
	s[5]="a$"
	s[6]="$"
	The suffix array of string "banana$"  is the array of indices of sorted suffixes.
	s[6]="$"
	s[5]="a$"
	s[3]="ana$"
	s[1]="anana$"
	s[0]="banana$"
	s[4]="na$"
	s[2]="nana$"
	so sa=[6,5,3,1,0,4,2]

        Returns
        -------
        pdarray
            The suffix arrays of the given strings

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
            Raised if there is a server-side error in executing group request or
            creating the pdarray encapsulating the return message
        """
        cmd = "segmentedSuffixAry"
        args ="{} {} {}".format( strings.objtype,
                                                        strings.offsets.name,
                                                        strings.bytes.name) 
        repMsg = generic_msg(cmd=cmd,args=args)
        return SArrays(*(cast(str,repMsg).split('+')))


@typechecked
def lcp_array(suffixarrays : SArrays, strings : Strings) -> SArrays:
        """
        Return the longest common prefix of given suffix arrays. The size/shape of each lcp
	arrays is the same as the corresponding suffix array. 
        -------
        SArrays 
            The LCP arrays of the given suffix arrays

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
            Raised if there is a server-side error in executing group request or
            creating the pdarray encapsulating the return message
        """
        cmd = "segmentedLCP"
        args= "{} {} {} {} {}".format( suffixarrays.objtype,
                                                        suffixarrays.offsets.name,
                                                        suffixarrays.bytes.name, 
                                                        strings.offsets.name,
                                                        strings.bytes.name) 
        repMsg = generic_msg(cmd=cmd,args=args)
        return SArrays(*(cast(str,repMsg).split('+')))

@typechecked
def suffix_array_file(filename: str)  -> tuple:
#def suffix_array_file(filename: str)  -> tuple[SArrays,Strings]:
        """
        This function is major used for testing correctness and performance
        Return the suffix array of given file name's content as a string. 
	A simple example of suffix array is as follow. Given string "banana$",
	all the suffixes are as follows. 
	s[0]="banana$"
	s[1]="anana$"
	s[2]="nana$"
	s[3]="ana$"
	s[4]="na$"
	s[5]="a$"
	s[6]="$"
	The suffix array of string "banana$"  is the array of indices of sorted suffixes.
	s[6]="$"
	s[5]="a$"
	s[3]="ana$"
	s[1]="anana$"
	s[0]="banana$"
	s[4]="na$"
	s[2]="nana$"
	so sa=[6,5,3,1,0,4,2]

        Returns
        -------
        pdarray
            The suffix arrays of the given strings

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
            Raised if there is a server-side error in executing group request or
            creating the pdarray encapsulating the return message
        """
        cmd = "segmentedSAFile"
        args= "{}".format( filename )
        repMsg = generic_msg(cmd=cmd,args=args)
        tmpmsg=cast(str,repMsg).split('+')
        sastr=tmpmsg[0:2]
        strstr=tmpmsg[2:4]
        suffixarray=SArrays(*(cast(str,sastr))) 
        originalstr=Strings(*(cast(str,strstr))) 
        return suffixarray,originalstr
#        return SArrays(*(cast(str,repMsg).split('+')))


@typechecked
def graph_file_read(Ne:int, Nv:int,Ncol:int,directed:int, filename: str)  -> Union[GraphD,GraphUD,GraphDW,GraphUDW]:
        """
        This function is used for creating a graph from a file.
        The file should like this
          1   5
          13  9
          4   8
          7   6
        This file means the edges are <1,5>,<13,9>,<4,8>,<7,6>. If additional column is added, it is the weight
        of each edge.
        Ne : the total number of edges of the graph
        Nv : the total number of vertices of the graph
        Ncol: how many column of the file. Ncol=2 means just edges (so no weight and weighted=0) 
              and Ncol=3 means there is weight for each edge (so weighted=1). 
        directed: 0 means undirected graph and 1 means directed graph
        Returns
        -------
        Graph
            The Graph class to represent the data

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd = "segmentedGraphFile"
        RCMFlag=0
        #args="{} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename);
        args="{} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,RCMFlag);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        if (int(Ncol) >2) :
             weighted=1
        else:
             weighted=0

        if (directed!=0)  :
           if (weighted!=0) :
               return GraphDW(*(cast(str,repMsg).split('+')))
           else:
               return GraphD(*(cast(str,repMsg).split('+')))
        else:
           if (weighted!=0) :
               return GraphUDW(*(cast(str,repMsg).split('+')))
           else:
               return GraphUD(*(cast(str,repMsg).split('+')))


@typechecked
def stream_file_read(Ne:int, Nv:int,Ncol:int,directed:int, filename: str,\
                     factor:int)  -> Union[GraphD,GraphUD,GraphDW,GraphUDW]:
        """
        This function is used for creating a graph from a file.
        The file should like this
          1   5
          13  9
          4   8
          7   6
        This file means the edges are <1,5>,<13,9>,<4,8>,<7,6>. If additional column is added, it is the weight
        of each edge.
        Ne : the total number of edges of the graph
        Nv : the total number of vertices of the graph
        Ncol: how many column of the file. Ncol=2 means just edges (so no weight and weighted=0) 
              and Ncol=3 means there is weight for each edge (so weighted=1). 
        directed: 0 means undirected graph and 1 means directed graph
        Returns
        -------
        Graph
            The Graph class to represent the data

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd = "segmentedStreamFile"
        args="{} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,factor);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        if (int(Ncol) >2) :
             weighted=1
        else:
             weighted=0

        if (directed!=0)  :
           if (weighted!=0) :
               return GraphDW(*(cast(str,repMsg).split('+')))
           else:
               return GraphD(*(cast(str,repMsg).split('+')))
        else:
           if (weighted!=0) :
               return GraphUDW(*(cast(str,repMsg).split('+')))
           else:
               return GraphUD(*(cast(str,repMsg).split('+')))


@typechecked
def rmat_gen (lgNv:int, Ne_per_v:int, p:float, directed: int,weighted:int) ->\
              Union[GraphD,GraphUD,GraphDW,GraphUDW]:
        """
        This function is for creating a graph using rmat graph generator
        Returns
        -------
        Graph
            The Graph class to represent the data

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd = "segmentedRMAT"
        RCMFlag=0
        #args= "{} {} {} {} {}".format(lgNv, Ne_per_v, p, directed, weighted)
        args= "{} {} {} {} {} {}".format(lgNv, Ne_per_v, p, directed, weighted,RCMFlag)
        msg = "segmentedRMAT {} {} {} {} {}".format(lgNv, Ne_per_v, p, directed, weighted)
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        if (directed!=0)  :
           if (weighted!=0) :
               return GraphDW(*(cast(str,repMsg).split('+')))
           else:
               return GraphD(*(cast(str,repMsg).split('+')))
        else:
           if (weighted!=0) :
               return GraphUDW(*(cast(str,repMsg).split('+')))
           else:
               return GraphUD(*(cast(str,repMsg).split('+')))

@typechecked
def graph_bfs (graph: Union[GraphD,GraphDW,GraphUD,GraphUDW], root: int ) -> pdarray:
        """
        This function is generating the breadth-first search vertices sequences in given graph
        starting from the given root vertex
        Returns
        -------
        pdarray
            The bfs vertices results

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd="segmentedGraphBFS"
        #if (cast(int,graph.directed)!=0)  :
        #DefaultRatio=0.75111
        DefaultRatio=-.60
        RCMFlag=0
        if (int(graph.directed)>0)  :
            if (int(graph.weighted)==0):
              # directed unweighted GraphD
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {} {}".format(
                 RCMFlag,\
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 root,DefaultRatio)
            else:
              # directed weighted GraphDW
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {} {} {} {}".format(
                 RCMFlag,\
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.v_weight.name,graph.e_weight.name,\
                 root,DefaultRatio)
        else:
            if (int(graph.weighted)==0):
              # undirected unweighted GraphUD
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
                 RCMFlag,\
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.srcR.name,graph.dstR.name,\
                 graph.start_iR.name,graph.neighbourR.name,\
                 root,DefaultRatio)
            else:
              # undirected weighted GraphUDW 15
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
                 RCMFlag,\
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.srcR.name,graph.dstR.name,\
                 graph.start_iR.name,graph.neighbourR.name,\
                 graph.v_weight.name,graph.e_weight.name,\
                 root,DefaultRatio)

        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        '''
        tmpmsg=cast(str,repMsg).split('+')
        levelstr=tmpmsg[0:1]
        vertexstr=tmpmsg[1:2]
        levelary=create_pdarray(*(cast(str,levelstr)) )
        
        vertexary=create_pdarray(*(cast(str,vertexstr)) )
        '''
        return create_pdarray(repMsg)
        #return (levelary,vertexary)

@typechecked
def graph_triangle (graph: Union[GraphD,GraphDW,GraphUD,GraphUDW]) -> pdarray:
        """
        This function will return the number of triangles in a static graph.
        Returns
        -------
        pdarray
            The total number of triangles.

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd="segmentedGraphTri"
        print("Yay pip3 actually worked")
        #if (cast(int,graph.directed)!=0)  :
        if (int(graph.directed)>0)  :
            if (int(graph.weighted)==0):
              # directed unweighted GraphD
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {}".format(
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name )
            else:
              # directed weighted GraphDW
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {}".format(
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.v_weight.name,graph.e_weight.name )
        else:
            print("I got here")
            if (int(graph.weighted)==0):
              # undirected unweighted GraphUD
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {} {} {}".format(
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.srcR.name,graph.dstR.name,\
                 graph.start_iR.name,graph.neighbourR.name )
            else:
              # undirected weighted GraphUDW 15
              #msg = "segmentedGraphBFS {} {} {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
              args = "{} {} {} {} {} {} {} {} {} {} {} {} {} {}".format(
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.srcR.name,graph.dstR.name,\
                 graph.start_iR.name,graph.neighbourR.name,\
                 graph.v_weight.name,graph.e_weight.name)

        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        '''
        tmpmsg=cast(str,repMsg).split('+')
        levelstr=tmpmsg[0:1]
        vertexstr=tmpmsg[1:2]
        levelary=create_pdarray(*(cast(str,levelstr)) )
        
        vertexary=create_pdarray(*(cast(str,vertexstr)) )
        '''
        return create_pdarray(repMsg)
        #return (levelary,vertexary)
        
@typechecked
def KTruss(graph: Union[GraphD,GraphDW,GraphUD,GraphUDW],kTrussValue:int) -> pdarray:
        #(Ne:int, Nv:int,Ncol:int,directed:int, filename: str)
        """
        This function will return the number of triangles in a static graph for each edge
        Returns
        -------
        pdarray
            The total number of triangles incident to each edge.

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd="segmentedTruss"
        #kTrussValue=4
        args = "{} {} {} {} {} {} {} {} {} {} {} {} {}".format(
                 kTrussValue,\
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.srcR.name,graph.dstR.name,\
                 graph.start_iR.name,graph.neighbourR.name )
        #repMsg = generic_msg(msg)
        #args="{} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename);
        repMsg = generic_msg(cmd=cmd,args=args)
        '''
        tmpmsg=cast(str,repMsg).split('+')
        levelstr=tmpmsg[0:1]
        vertexstr=tmpmsg[1:2]
        levelary=create_pdarray(*(cast(str,levelstr)) )
        
        vertexary=create_pdarray(*(cast(str,vertexstr)) )
        '''
        return create_pdarray(repMsg)

@typechecked
def graph_triangle_edge (graph: Union[GraphD,GraphDW,GraphUD,GraphUDW],kTrussValue:int) -> pdarray:
        #(Ne:int, Nv:int,Ncol:int,directed:int, filename: str)
        """
        This function will return the number of triangles in a static graph for each edge
        Returns
        -------
        pdarray
            The total number of triangles incident to each edge.

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd="segmentedGraphTriEdge"
        #Change this for Chapel
        #if (cast(int,graph.directed)!=0)  :
        #kTrussValue=4
        args = "{} {} {} {} {} {} {} {} {} {} {} {} {}".format(
                 kTrussValue,\
                 graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.weighted,\
                 graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,\
                 graph.srcR.name,graph.dstR.name,\
                 graph.start_iR.name,graph.neighbourR.name )
        #repMsg = generic_msg(msg)
        #args="{} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename);
        repMsg = generic_msg(cmd=cmd,args=args)
        '''
        tmpmsg=cast(str,repMsg).split('+')
        levelstr=tmpmsg[0:1]
        vertexstr=tmpmsg[1:2]
        levelary=create_pdarray(*(cast(str,levelstr)) )
        
        vertexary=create_pdarray(*(cast(str,vertexstr)) )
        '''
        return create_pdarray(repMsg)

@typechecked
def stream_tri_cnt(Ne:int, Nv:int,Ncol:int,directed:int, filename: str,\
                     factor:int)  -> pdarray:
        cmd = "segmentedStreamTri"
        args="{} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,factor);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        return create_pdarray(repMsg)

@typechecked
def streamHead_tri_cnt(Ne:int, Nv:int,Ncol:int,directed:int, filename: str,\
                     factor:int)  -> pdarray:
        cmd = "segmentedHeadStreamTri"
        args="{} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,factor);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        return create_pdarray(repMsg)

@typechecked
def streamMid_tri_cnt(Ne:int, Nv:int,Ncol:int,directed:int, filename: str,\
                     factor:int)  -> pdarray:
        cmd = "segmentedMidStreamTri"
        args="{} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,factor);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        return create_pdarray(repMsg)

@typechecked
def streamTail_tri_cnt(Ne:int, Nv:int,Ncol:int,directed:int, filename: str,\
                     factor:int)  -> pdarray:
        cmd = "segmentedTailStreamTri"
        args="{} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,factor);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        return create_pdarray(repMsg)

@typechecked
def streamPL_tri_cnt(Ne:int, Nv:int,Ncol:int,directed:int, filename: str,\
                     factor:int, case:int)  -> pdarray:
        """
        This function is used for creating a graph from a file.
        The file should like this
          1   5
          13  9
          4   8
          7   6
        This file means the edges are <1,5>,<13,9>,<4,8>,<7,6>. If additional column is added, it is the weight
        of each edge.
        Ne : the total number of edges of the graph
        Nv : the total number of vertices of the graph
        Ncol: how many column of the file. Ncol=2 means just edges (so no weight and weighted=0) 
              and Ncol=3 means there is weight for each edge (so weighted=1). 
        factor: the sampling graph will be 1/factor of the original one
        case: 0 calculate the average, 1: using power law regression paramter 2: using normal regression parameter 
        Returns
        -------
        Graph
            The Graph class to represent the data

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd = "segmentedPLStreamTri"
        args="{} {} {} {} {} {} {}".format(Ne, Nv, Ncol,directed, filename,factor,case);
        #repMsg = generic_msg(msg)
        repMsg = generic_msg(cmd=cmd,args=args)
        return create_pdarray(repMsg)





'''
@typechecked
def graph_dfs (graph: Union[GraphD,GraphUD,GraphDW,GraphUDW], root: int ) -> tuple:
        msg = "segmentedGraphDFS {} {} {} {} {} {} {} {}".format(graph.n_vertices,graph.n_edges,\
                 graph.directed,graph.src.name,graph.dst.name,\
                 graph.start_i.name,graph.neighbour.name,root)
        repMsg = generic_msg(msg)
        tmpmsg=cast(str,repMsg).split('+')
        levelstr=tmpmsg[0:1]
        vertexstr=tmpmsg[1:2]
        levelary=create_pdarray(*(cast(str,levelstr)) )
        
        vertexary=create_pdarray(*(cast(str,vertexstr)) )
        return (levelary,vertexary)

@typechecked
def components (graph:  Union[GraphD,GraphUD,GraphDW,GraphUDW] ) -> int :
        """
        This function returns the number of components of the given graph
        Returns
        -------
        int
            The total number of components

        See Also
        --------

        Notes
        -----
        
        Raises
        ------  
        RuntimeError
        """
        cmd = "segmentedGraphComponents"
        args= "{} {}".format(graph.edges.name,graph.vertices.name)
        msg = "segmentedGraphComponents {} {}".format(graph.edges.name,graph.vertices.name)
        repMsg = generic_msg(cmd=cmd,args=args)
        return cast(int,repMsg)
'''