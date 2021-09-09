import os, platform, secrets, json
from os.path import expanduser
from pathlib import Path
from collections import defaultdict 
from typeguard import typechecked
from arkouda import io_util

username_tokenizer = defaultdict(lambda x : x.split('/')) #type: ignore
username_tokenizer['Windows'] = lambda x : x.split('\\')
username_tokenizer['Linux'] = lambda x : x.split('/')
username_tokenizer['Darwin'] = lambda x : x.split('/')

@typechecked
def generate_token(length : int=32) -> str:
    """
    Uses the secrets.token_hex() method to generate a
    a hexidecimal token

    Parameters
    ----------
    length : int
        The desired length of token
        
    Returns
    -------
    str
        The hexidecimal string generated by Python
        
    Notes
    -----
    This method uses the Python secrets.token_hex method
    """
    return secrets.token_hex(length//2)

def get_home_directory() -> str:
    """
    A platform-independent means of finding path to
    the current user's home directory    
    
    Returns
    -------
    str
        The user's home directory path
    
    Notes
    -----
    This method uses the Python os.path.expanduser method
    to retrieve the user's home directory
    """
    return expanduser("~")

def get_arkouda_client_directory() -> Path:
    """
    A platform-independent means of finding path to
    the current user's .arkouda directory where artifacts
    such as server access tokens are stored. 

    Returns
    -------
    Path
        Path corresponding to the .arkouda directory path

    Notes
    -----
    The default implementation is to place the .arkouda 
    directory in the current user's home directory. The
    default can be overridden by seting the ARKOUDA_HOME
    environment variable.
    """
    arkouda_parent_dir = os.getenv('ARKOUDA_CLIENT_DIRECTORY')
    if not arkouda_parent_dir:
        arkouda_parent_dir = get_home_directory()
    return io_util.get_directory('{}{}.arkouda'.\
                format(arkouda_parent_dir,os.sep)).absolute()

def get_username() -> str:
    """
    A platform-independent means of retrieving the current
    user's username for the host system.

    Returns
    -------
    str
        The username in the form of string

    Raises
    ------
    EnvironmentError
        Raised if the host OS is unsupported
    
    Notes
    -----
    The curreently supported operating systems are Windows, Linux, 
    and MacOS AKA Darwin
    """
    try:
        u_tokens = \
          username_tokenizer[platform.system()](get_home_directory())
    except KeyError as ke:
        raise EnvironmentError('Unsupported OS: {}'.format(ke))
    return u_tokens[-1]

@typechecked
def generate_username_token_json(token : str) -> str:
    """
    Generates a JSON object encapsulating the user's username
    and token for connecting to an arkouda server with basic
    authentication enabled

    Parameters
    ----------
    token : string
        The token to be used to access arkouda server
        
    Returns
    -------
    str
        The JSON-formatted string encapsulating username and token
    """
    return json.dumps({'username' : get_username(),
                       'token' : token})
