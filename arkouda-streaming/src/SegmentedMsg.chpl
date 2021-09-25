module SegmentedMsg {
  use Reflection;
  use Errors;
  use Logging;
  use Message;
  use SegmentedArray;
  use ServerErrorStrings;
  use ServerConfig;
  use MultiTypeSymbolTable;
  use MultiTypeSymEntry;
  use RandArray;
  use IO;
  use GenSymIO only jsonToPdArray,jsonToPdArrayInt;

  use SymArrayDmap;
  use SACA;
  use Random;
  use RadixSortLSD;
  use Set;
  use DistributedBag;
  public use ArgSortMsg;
  use Time;
  use CommAggregation;
  use Sort;
  use Map;
  use DistributedDeque;

  private config const DEBUG = false;
  const smLogger = new Logger();
  
  if v {
      smLogger.level = LogLevel.DEBUG;
  } else {
      smLogger.level = LogLevel.INFO;
  }

  proc randomStringsMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var (lenStr, dist, charsetStr, arg1str, arg2str, seedStr)
          = payload.splitMsgToTuple(6);
      var len = lenStr: int;
      var charset = str2CharSet(charsetStr);
      var segName = st.nextName();
      var valName = st.nextName();
      var repMsg: string;
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
             "dist: %s segName: %t valName: %t".format(dist.toLower(),segName,valName));
      select dist.toLower() {
          when "uniform" {
              var minLen = arg1str:int;
              var maxLen = arg2str:int;
              // Lengths + 2*segs + 2*vals (copied to SymTab)
              overMemLimit(8*len + 16*len + (maxLen + minLen)*len);
              var (segs, vals) = newRandStringsUniformLength(len, minLen, maxLen, charset, seedStr);
              var segEntry = new shared SymEntry(segs);
              var valEntry = new shared SymEntry(vals);
              st.addEntry(segName, segEntry);
              st.addEntry(valName, valEntry);
              repMsg = 'created ' + st.attrib(segName) + '+created ' + st.attrib(valName);
          }
          when "lognormal" {
              var logMean = arg1str:real;
              var logStd = arg2str:real;
              // Lengths + 2*segs + 2*vals (copied to SymTab)
              overMemLimit(8*len + 16*len + exp(logMean + (logStd**2)/2):int*len);
              var (segs, vals) = newRandStringsLogNormalLength(len, logMean, logStd, charset, seedStr);
              var segEntry = new shared SymEntry(segs);
              var valEntry = new shared SymEntry(vals);
              st.addEntry(segName, segEntry);
              st.addEntry(valName, valEntry);
              repMsg = 'created ' + st.attrib(segName) + '+created ' + st.attrib(valName);
          }
          otherwise { 
              var errorMsg = notImplementedError(pn, dist);      
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);  
              return new MsgTuple(errorMsg, MsgType.ERROR);    
          }
      }

      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);      
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segmentLengthsMsg(cmd: string, payload: string, 
                                          st: borrowed SymTab): MsgTuple throws {

    var pn = Reflection.getRoutineName();
    var (objtype, segName, valName) = payload.splitMsgToTuple(3);

    // check to make sure symbols defined
    st.check(segName);
    st.check(valName);
    
    var rname = st.nextName();
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
            "cmd: %s objtype: %t segName: %t valName: %t".format(
                   cmd,objtype,segName,valName));

    select objtype {
      when "str" {
        var strings = getSegString(segName, valName, st);
        var lengths = st.addEntry(rname, strings.size, int);
        // Do not include the null terminator in the length
        lengths.a = strings.getLengths() - 1;
      }
      when "int" {
        var sarrays = new owned SegSArray(segName, valName, st);
        var lengths = st.addEntry(rname, sarrays.size, int);
        // Do not include the null terminator in the length
        lengths.a = sarrays.getLengths() - 1;
      }
      otherwise {
          var errorMsg = notImplementedError(pn, "%s".format(objtype));
          smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);                      
          return new MsgTuple(errorMsg, MsgType.ERROR);
      }
    }

    var repMsg = "created "+st.attrib(rname);
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segmentedEfuncMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var repMsg: string;
      var (subcmd, objtype, segName, valName, valtype, valStr) = 
                                              payload.splitMsgToTuple(6);

      // check to make sure symbols defined
      st.check(segName);
      st.check(valName);

      var json = jsonToPdArray(valStr, 1);
      var val = json[json.domain.low];
      var rname = st.nextName();
    
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                         "cmd: %s subcmd: %s objtype: %t valtype: %t".format(
                          cmd,subcmd,objtype,valtype));
    
        select (objtype, valtype) {
          when ("str", "str") {
            var strings = getSegString(segName, valName, st);
            select subcmd {
                when "contains" {
                var truth = st.addEntry(rname, strings.size, bool);
                truth.a = strings.substringSearch(val, SearchMode.contains);
                repMsg = "created "+st.attrib(rname);
            }
            when "startswith" {
                var truth = st.addEntry(rname, strings.size, bool);
                truth.a = strings.substringSearch(val, SearchMode.startsWith);
                repMsg = "created "+st.attrib(rname);
            }
            when "endswith" {
                var truth = st.addEntry(rname, strings.size, bool);
                truth.a = strings.substringSearch(val, SearchMode.endsWith);
                repMsg = "created "+st.attrib(rname);
            }
            otherwise {
               var errorMsg = notImplementedError(pn, "subcmd: %s, (%s, %s)".format(
                         subcmd, objtype, valtype));
               smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
               return new MsgTuple(errorMsg, MsgType.ERROR);
            }
          }
        }
        otherwise {
          var errorMsg = "(%s, %s)".format(objtype, valtype);
          smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
          return new MsgTuple(notImplementedError(pn, errorMsg), MsgType.ERROR);
        }
      }

      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }

proc segmentedPeelMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    var (subcmd, objtype, segName, valName, valtype, valStr,
         idStr, kpStr, lStr, jsonStr) = payload.splitMsgToTuple(10);

    // check to make sure symbols defined
    st.check(segName);
    st.check(valName);

    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                         "cmd: %s subcmd: %s objtype: %t valtype: %t".format(
                          cmd,subcmd,objtype,valtype));

    select (objtype, valtype) {
    when ("str", "str") {
      var strings = getSegString(segName, valName, st);
      select subcmd {
        when "peel" {
          var times = valStr:int;
          var includeDelimiter = (idStr.toLower() == "true");
          var keepPartial = (kpStr.toLower() == "true");
          var left = (lStr.toLower() == "true");
          var json = jsonToPdArray(jsonStr, 1);
          var val = json[json.domain.low];
          var loname = st.nextName();
          var lvname = st.nextName();
          var roname = st.nextName();
          var rvname = st.nextName();
          select (includeDelimiter, keepPartial, left) {
          when (false, false, false) {
            var (lo, lv, ro, rv) = strings.peel(val, times, false, false, false);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (false, false, true) {
            var (lo, lv, ro, rv) = strings.peel(val, times, false, false, true);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (false, true, false) {
            var (lo, lv, ro, rv) = strings.peel(val, times, false, true, false);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (false, true, true) {
            var (lo, lv, ro, rv) = strings.peel(val, times, false, true, true);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (true, false, false) {
            var (lo, lv, ro, rv) = strings.peel(val, times, true, false, false);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (true, false, true) {
            var (lo, lv, ro, rv) = strings.peel(val, times, true, false, true);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (true, true, false) {
            var (lo, lv, ro, rv) = strings.peel(val, times, true, true, false);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } when (true, true, true) {
            var (lo, lv, ro, rv) = strings.peel(val, times, true, true, true);
            st.addEntry(loname, new shared SymEntry(lo));
            st.addEntry(lvname, new shared SymEntry(lv));
            st.addEntry(roname, new shared SymEntry(ro));
            st.addEntry(rvname, new shared SymEntry(rv));
          } otherwise {
              var errorMsg = notImplementedError(pn, 
                               "subcmd: %s, (%s, %s)".format(subcmd, objtype, valtype));
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);                            
              }
          }
          repMsg = "created %s+created %s+created %s+created %s".format(st.attrib(loname),
                                                                        st.attrib(lvname),
                                                                        st.attrib(roname),
                                                                        st.attrib(rvname));
        }
        otherwise {
            var errorMsg = notImplementedError(pn, 
                              "subcmd: %s, (%s, %s)".format(subcmd, objtype, valtype));
            smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
            return new MsgTuple(errorMsg, MsgType.ERROR);                                          
        }
      }
    }
    otherwise {
        var errorMsg = notImplementedError(pn, "(%s, %s)".format(objtype, valtype));
        smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
        return new MsgTuple(errorMsg, MsgType.ERROR);       
      }
    }
    
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segmentedHashMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    var (objtype, segName, valName) = payload.splitMsgToTuple(3);

    // check to make sure symbols defined
    st.check(segName);
    st.check(valName);

    select objtype {
        when "str" {
            var strings = getSegString(segName, valName, st);
            var hashes = strings.hash();
            var name1 = st.nextName();
            var hash1 = st.addEntry(name1, hashes.size, int);
            var name2 = st.nextName();
            var hash2 = st.addEntry(name2, hashes.size, int);
            forall (h, h1, h2) in zip(hashes, hash1.a, hash2.a) {
                (h1,h2) = h:(int,int);
            }
            var repMsg = "created " + st.attrib(name1) + "+created " + st.attrib(name2);
            smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
            return new MsgTuple(repMsg, MsgType.NORMAL);
        }
/*
        when "int" {
            var sarrays = new owned SegSArray(segName, valName, st);
            var hashes = sarrays.hash();
            var name1 = st.nextName();
            var hash1 = st.addEntry(name1, hashes.size, int);
            var name2 = st.nextName();
            var hash2 = st.addEntry(name2, hashes.size, int);
            forall (h, h1, h2) in zip(hashes, hash1.a, hash2.a) {
                (h1,h2) = h:(int,int);
            }
            return "created " + st.attrib(name1) + "+created " + st.attrib(name2);
        }
*/
        otherwise {
            var errorMsg = notImplementedError(pn, objtype);
            smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }
    }
  }


  /*
   * Assigns a segIntIndex, sliceIndex, or pdarrayIndex to the incoming payload
   * consisting of a sub-command, object type, offset SymTab key, array SymTab
   * key, and index value for the incoming payload.
   * 
   * Note: the sub-command indicates the index type which can be one of the following:
   * 1. intIndex : setIntIndex
   * 2. sliceIndex : segSliceIndex
   * 3. pdarrayIndex : segPdarrayIndex
  */ 
  proc segmentedIndexMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    // 'subcmd' is the type of indexing to perform
    // 'objtype' is the type of segmented array
    var (subcmd, objtype, rest) = payload.splitMsgToTuple(3);
    var fields = rest.split();
    var args: [1..#fields.size] string = fields; // parsed by subroutines
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                            "subcmd: %s objtype: %s rest: %s".format(subcmd,objtype,rest));
    try {
        select subcmd {
            when "intIndex" {
                return segIntIndex(objtype, args, st);
            }
            when "sliceIndex" {
                return segSliceIndex(objtype, args, st);
            }
            when "pdarrayIndex" {
                return segPdarrayIndex(objtype, args, st);
            }
            otherwise {
                var errorMsg = "Error in %s, unknown subcommand %s".format(pn, subcmd);
                smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
        }
    } catch e: OutOfBoundsError {
        var errorMsg = "index out of bounds";
        smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
        return new MsgTuple(errorMsg, MsgType.ERROR);
    } catch e: Error {
        var errorMsg = "unknown cause %t".format(e);
        smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
        return new MsgTuple(errorMsg, MsgType.ERROR);
    }
  }
 
  /*
  Returns the object corresponding to the index
  */ 
  proc segIntIndex(objtype: string, args: [] string, 
                                         st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();

      // check to make sure symbols defined
      st.check(args[1]);
      st.check(args[2]);
      
      select objtype {
          when "str" {
              // Make a temporary strings array
              var strings = getSegString(args[1], args[2], st);
              // Parse the index
              var idx = args[3]:int;
              // TO DO: in the future, we will force the client to handle this
              idx = convertPythonIndexToChapel(idx, strings.size);
              var s = strings[idx];

              var repMsg = "item %s %jt".format("str", s);
              smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg); 
              return new MsgTuple(repMsg, MsgType.NORMAL);
          }
          when "int" {
              // Make a temporary int array
              var arrays = new owned SegSArray(args[1], args[2], st);
              // Parse the index
              var idx = args[3]:int;
              // TO DO: in the future, we will force the client to handle this
              idx = convertPythonIndexToChapel(idx, arrays.size);
              var s = arrays[idx];
              var repMsg="item %s %jt".format("int", s);
              smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg); 
              return new MsgTuple(repMsg, MsgType.NORMAL);
          }
          otherwise { 
              var errorMsg = notImplementedError(pn, objtype); 
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);                          
          }
      }
  }

  /* Allow Python-style negative indices. */
  proc convertPythonIndexToChapel(pyidx: int, high: int): int {
    var chplIdx: int;
    if (pyidx < 0) {
      chplIdx = high + 1 + pyidx;
    } else {
      chplIdx = pyidx;
    }
    return chplIdx;
  }

  proc segSliceIndex(objtype: string, args: [] string, 
                                         st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();

    // check to make sure symbols defined
    st.check(args[1]);
    st.check(args[2]);

    select objtype {
        when "str" {
            // Make a temporary string array
            var strings = getSegString(args[1], args[2], st);

            // Parse the slice parameters
            var start = args[3]:int;
            var stop = args[4]:int;
            var stride = args[5]:int;

            // Only stride-1 slices are allowed for now
            if (stride != 1) { 
                var errorMsg = notImplementedError(pn, "stride != 1"); 
                smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
            // TO DO: in the future, we will force the client to handle this
            var slice: range(stridable=true) = convertPythonSliceToChapel(start, stop, stride);
            var newSegName = st.nextName();
            var newValName = st.nextName();
            // Compute the slice
            var (newSegs, newVals) = strings[slice];
            // Store the resulting offsets and bytes arrays
            var newSegsEntry = new shared SymEntry(newSegs);
            var newValsEntry = new shared SymEntry(newVals);
            st.addEntry(newSegName, newSegsEntry);
            st.addEntry(newValName, newValsEntry);
            var repMsg = "created " + st.attrib(newSegName) + " +created " + st.attrib(newValName);
            smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg); 
            return new MsgTuple(repMsg, MsgType.NORMAL);
      }
      when "int" {
            // Make a temporary integer  array
            var sarrays = new owned SegSArray(args[1], args[2], st);
            // Parse the slice parameters
            var start = args[3]:int;
            var stop = args[4]:int;
            var stride = args[5]:int;
            // Only stride-1 slices are allowed for now
            if (stride != 1) { 
                var errorMsg = notImplementedError(pn, "stride != 1"); 
                smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
            // TO DO: in the future, we will force the client to handle this
            var slice: range(stridable=true) = convertPythonSliceToChapel(start, stop, stride);
            var newSegName = st.nextName();
            var newValName = st.nextName();
            // Compute the slice
            var (newSegs, newVals) = sarrays[slice];
            // Store the resulting offsets and bytes arrays
            var newSegsEntry = new shared SymEntry(newSegs);
            var newValsEntry = new shared SymEntry(newVals);
            st.addEntry(newSegName, newSegsEntry);
            st.addEntry(newValName, newValsEntry);
        
            var repMsg = "created " + st.attrib(newSegName) + " +created " + st.attrib(newValName);
            smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg); 
            return new MsgTuple(repMsg, MsgType.NORMAL);
        }
        otherwise {
            var errorMsg = notImplementedError(pn, objtype);
            smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
            return new MsgTuple(errorMsg, MsgType.ERROR);          
        }
    }
  }

  proc convertPythonSliceToChapel(start:int, stop:int, stride:int=1): range(stridable=true) {
    var slice: range(stridable=true);
    // convert python slice to chapel slice
    // backwards iteration with negative stride
    if  (start > stop) & (stride < 0) {slice = (stop+1)..start by stride;}
    // forward iteration with positive stride
    else if (start <= stop) & (stride > 0) {slice = start..(stop-1) by stride;}
    // BAD FORM start < stop and stride is negative
    else {slice = 1..0;}
    return slice;
  }

  proc segPdarrayIndex(objtype: string, args: [] string, 
                                 st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();

    // check to make sure symbols defined
    st.check(args[1]);
    st.check(args[2]);

    var newSegName = st.nextName();
    var newValName = st.nextName();
    
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                  "objtype:%s".format(objtype));
    
    select objtype {
        when "str" {
            var strings = getSegString(args[1], args[2], st);
            var iname = args[3];
            var gIV: borrowed GenSymEntry = st.lookup(iname);
            try {
                select gIV.dtype {
                    when DType.Int64 {
                        var iv = toSymEntry(gIV, int);
                        var (newSegs, newVals) = strings[iv.a];
                        var newSegsEntry = new shared SymEntry(newSegs);
                        var newValsEntry = new shared SymEntry(newVals);
                        st.addEntry(newSegName, newSegsEntry);
                        st.addEntry(newValName, newValsEntry);
                    }
                    when DType.Bool {
                        var iv = toSymEntry(gIV, bool);
                        var (newSegs, newVals) = strings[iv.a];
                        var newSegsEntry = new shared SymEntry(newSegs);
                        var newValsEntry = new shared SymEntry(newVals);
                        st.addEntry(newSegName, newSegsEntry);
                        st.addEntry(newValName, newValsEntry);
                    }
                    otherwise {
                        var errorMsg = "("+objtype+","+dtype2str(gIV.dtype)+")";
                        smLogger.error(getModuleName(),getRoutineName(),
                                                      getLineNumber(),errorMsg); 
                        return new MsgTuple(notImplementedError(pn,errorMsg), MsgType.ERROR);
                    }
                }
            } catch e: Error {
                var errorMsg =  e.message();
                smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
        }
        when "int" {
            var sarrays = new owned SegSArray(args[1], args[2], st);
            var iname = args[3];
            var gIV: borrowed GenSymEntry = st.lookup(iname);
            try {
                select gIV.dtype {
                    when DType.Int64 {
                        var iv = toSymEntry(gIV, int);
                        var (newSegs, newVals) = sarrays[iv.a];
                        var newSegsEntry = new shared SymEntry(newSegs);
                        var newValsEntry = new shared SymEntry(newVals);
                        st.addEntry(newSegName, newSegsEntry);
                        st.addEntry(newValName, newValsEntry);
                    }
                    when DType.Bool {
                        var iv = toSymEntry(gIV, bool);
                        var (newSegs, newVals) = sarrays[iv.a];
                        var newSegsEntry = new shared SymEntry(newSegs);
                        var newValsEntry = new shared SymEntry(newVals);
                        st.addEntry(newSegName, newSegsEntry);
                        st.addEntry(newValName, newValsEntry);
                    }
                    otherwise {
                        var errorMsg = "("+objtype+","+dtype2str(gIV.dtype)+")";
                        smLogger.error(getModuleName(),getRoutineName(),
                                                      getLineNumber(),errorMsg); 
                        return new MsgTuple(errorMsg, MsgType.ERROR);          
                    }
                }
            } catch e: Error {
                var errorMsg= "Error: %t".format(e.message());
                smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
        }
        otherwise {
            var errorMsg = "unsupported objtype: %t".format(objtype);
            smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(notImplementedError(pn, objtype), MsgType.ERROR);
        }
    }
    var repMsg = "created " + st.attrib(newSegName) + "+created " + st.attrib(newValName);
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);

    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segBinopvvMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    var (op,
         // Type and attrib names of left segmented array
         ltype, lsegName, lvalName,
         // Type and attrib names of right segmented array
         rtype, rsegName, rvalName, leftStr, jsonStr)
           = payload.splitMsgToTuple(9);

    // check to make sure symbols defined
    st.check(lsegName);
    st.check(lvalName);
    st.check(rsegName);
    st.check(rvalName);

    select (ltype, rtype) {
        when ("str", "str") {
            var lstrings = getSegString(lsegName, lvalName, st);
            var rstrings = getSegString(rsegName, rvalName, st);

            select op {
                when "==" {
                    var rname = st.nextName();
                    var e = st.addEntry(rname, lstrings.size, bool);
                    e.a = (lstrings == rstrings);
                    repMsg = "created " + st.attrib(rname);
                }
                when "!=" {
                    var rname = st.nextName();
                    var e = st.addEntry(rname, lstrings.size, bool);
                    e.a = (lstrings != rstrings);
                    repMsg = "created " + st.attrib(rname);
                }
                when "stick" {
                    var left = (leftStr.toLower() != "false");
                    var json = jsonToPdArray(jsonStr, 1);
                    const delim = json[json.domain.low];
                    var oname = st.nextName();
                    var vname = st.nextName();
                    if left {
                        var (newOffsets, newVals) = lstrings.stick(rstrings, delim, false);
                        st.addEntry(oname, new shared SymEntry(newOffsets));
                        st.addEntry(vname, new shared SymEntry(newVals));
                    } else {
                        var (newOffsets, newVals) = lstrings.stick(rstrings, delim, true);
                        st.addEntry(oname, new shared SymEntry(newOffsets));
                        st.addEntry(vname, new shared SymEntry(newVals));
                    }
                    repMsg = "created %s+created %s".format(st.attrib(oname), st.attrib(vname));
                    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
                }
                otherwise {
                    var errorMsg = notImplementedError(pn, ltype, op, rtype);
                    smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                    return new MsgTuple(errorMsg, MsgType.ERROR);
                }
              }
           }
       otherwise {
           var errorMsg = unrecognizedTypeError(pn, "("+ltype+", "+rtype+")");
           smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
           return new MsgTuple(errorMsg, MsgType.ERROR);
       } 
    }

    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segBinopvvIntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    var (op,
         // Type and attrib names of left segmented array
         ltype, lsegName, lvalName,
         // Type and attrib names of right segmented array
         rtype, rsegName, rvalName, leftStr, jsonStr)
           = payload.splitMsgToTuple(9);

    // check to make sure symbols defined
    st.check(lsegName);
    st.check(lvalName);
    st.check(rsegName);
    st.check(rvalName);

    select (ltype, rtype) {
        when ("int", "int") {
          var lsa = new owned SegSArray(lsegName, lvalName, st);
          var rsa = new owned SegSArray(rsegName, rvalName, st);
          select op {
              when "==" {
                var rname = st.nextName();
                var e = st.addEntry(rname, lsa.size, bool);
                e.a = (lsa == rsa);
                repMsg = "created " + st.attrib(rname);
              }
              when "!=" {
                var rname = st.nextName();
                var e = st.addEntry(rname, lsa.size, bool);
                e.a = (lsa != rsa);
                repMsg = "created " + st.attrib(rname);
              }
              otherwise {
                var errorMsg= notImplementedError(pn, ltype, op, rtype);
                smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
              }
          }
        }
        otherwise {
          var errorMsg= unrecognizedTypeError(pn, "("+ltype+", "+rtype+")");
          smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
          return new MsgTuple(errorMsg, MsgType.ERROR);
        } 
    }
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(), repMsg);
    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segBinopvsMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var repMsg: string;
      var (op, objtype, segName, valName, valtype, encodedVal)
          = payload.splitMsgToTuple(6);

      // check to make sure symbols defined
      st.check(segName);
      st.check(valName);

      var json = jsonToPdArray(encodedVal, 1);
      var value = json[json.domain.low];
      var rname = st.nextName();

      select (objtype, valtype) {
          when ("str", "str") {
              var strings = getSegString(segName, valName, st);
              select op {
                  when "==" {
                      var e = st.addEntry(rname, strings.size, bool);
                      e.a = (strings == value);
                  }
                  when "!=" {
                      var e = st.addEntry(rname, strings.size, bool);
                      e.a = (strings != value);
                  }
                  otherwise {
                      var errorMsg = notImplementedError(pn, objtype, op, valtype);
                      smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                      return new MsgTuple(errorMsg, MsgType.ERROR);
                  }
              }
          }
          otherwise {
              var errorMsg = unrecognizedTypeError(pn, "("+objtype+", "+valtype+")");
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
              return new MsgTuple(errorMsg, MsgType.ERROR);
          } 
      }

      repMsg = "created %s".format(st.attrib(rname));
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(), repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }


  proc segBinopvsIntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    var (op, objtype, segName, valName, valtype, encodedVal)
          = payload.splitMsgToTuple(6);

    // check to make sure symbols defined
    st.check(segName);
    st.check(valName);
    var json = jsonToPdArrayInt(encodedVal, 1);
    var value = json[json.domain.low];
    var rname = st.nextName();
    select (objtype, valtype) {
    when ("int", "int") {
      var sarrays  = new owned SegSArray(segName, valName, st);
      select op {
        when "==" {
          var e = st.addEntry(rname, sarrays.size, bool);
          var tmp=sarrays[sarrays.offsets.aD.low]:int;
          e.a = (tmp == value);
        }
        when "!=" {
          var e = st.addEntry(rname, sarrays.size, bool);
          var tmp=sarrays[sarrays.offsets.aD.low]:int;
          e.a = (tmp != value);
        }
        otherwise {
          var errorMsg= notImplementedError(pn, objtype, op, valtype);
          smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
          return new MsgTuple(errorMsg, MsgType.ERROR);
        }
        }
    }
    otherwise {
        var errorMsg= unrecognizedTypeError(pn, "("+objtype+", "+valtype+")");
        smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
        return new MsgTuple(errorMsg, MsgType.ERROR);
    } 
    }
    repMsg= "created " + st.attrib(rname);
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(), repMsg);
    return new MsgTuple(repMsg, MsgType.NORMAL);

  }

  proc segIn1dMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var repMsg: string;
      var (mainObjtype, mainSegName, mainValName, testObjtype, testSegName,
         testValName, invertStr) = payload.splitMsgToTuple(7);

      // check to make sure symbols defined
      st.check(mainSegName);
      st.check(mainValName);
      st.check(testSegName);
      st.check(testValName);

      var invert: bool;
      if invertStr == "True" {invert = true;
      } else if invertStr == "False" {invert = false;
      } else {
          var errorMsg = "Invalid argument in %s: %s (expected True or False)".format(pn, invertStr);
          smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
          return new MsgTuple(errorMsg, MsgType.ERROR);
      }
    
      var rname = st.nextName();
 
      select (mainObjtype, testObjtype) {
          when ("str", "str") {
              var mainStr = getSegString(mainSegName, mainValName, st);
              var testStr = getSegString(testSegName, testValName, st);
              var e = st.addEntry(rname, mainStr.size, bool);
              if invert {
                  e.a = !in1d(mainStr, testStr);
              } else {
                  e.a = in1d(mainStr, testStr);
              }
          }
          otherwise {
              var errorMsg = unrecognizedTypeError(pn, "("+mainObjtype+", "+testObjtype+")");
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);            
          }
      }

      repMsg = "created " + st.attrib(rname);
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  // this function is added for suffix array
  proc segIn1dIntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
    var pn = Reflection.getRoutineName();
    var repMsg: string;
    var (mainObjtype, mainSegName, mainValName, testObjtype, testSegName,
         testValName, invertStr) = payload.splitMsgToTuple(7);

    // check to make sure symbols defined
    st.check(mainSegName);
    st.check(mainValName);
    st.check(testSegName);
    st.check(testValName);

    var invert: bool;
    if invertStr == "True" {invert = true;}
    else if invertStr == "False" {invert = false;}
    else {
          var errorMsg="Error: Invalid argument in %s: %s (expected True or False)".format(pn, invertStr);
          return new MsgTuple(errorMsg, MsgType.ERROR);
    }
    var rname = st.nextName();
    select (mainObjtype, testObjtype) {
    when ("int", "int") {
      var mainSA = new owned SegSArray(mainSegName, mainValName, st);
      var testSA = new owned SegSArray(testSegName, testValName, st);
      var e = st.addEntry(rname, mainSA.size, bool);
      if invert {
        e.a = !in1d_Int(mainSA, testSA);
      } else {
        e.a = in1d_Int(mainSA, testSA);
      }
    }
    otherwise {
        var errorMsg = unrecognizedTypeError(pn, "("+mainObjtype+", "+testObjtype+")");
        smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
        return new MsgTuple(errorMsg, MsgType.ERROR);            
      }
    }
    repMsg= "created " + st.attrib(rname);
    smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
    return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segGroupMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var (objtype, segName, valName) = payload.splitMsgToTuple(3);

      // check to make sure symbols defined
      st.check(segName);
      st.check(valName);
      
      var rname = st.nextName();
      select (objtype) {
          when "str" {
              var strings = getSegString(segName, valName, st);
              var iv = st.addEntry(rname, strings.size, int);
              iv.a = strings.argGroup();
          }
          otherwise {
              var errorMsg = notImplementedError(pn, "("+objtype+")");
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);            
          }
   }

      var repMsg =  "created " + st.attrib(rname);
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }



  proc segSuffixArrayMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var (objtype, segName, valName) = payload.splitMsgToTuple(3);
      var repMsg: string;

      // check to make sure symbols defined
      st.check(segName);
      st.check(valName);

      //var strings = new owned SegString(segName, valName, st);
      var strings = getSegString(segName, valName, st);
      var size=strings.size;
      var nBytes = strings.nBytes;
      var length=strings.getLengths();
      var offsegs = (+ scan length) - length;
      var algorithmNum=2:int; //2:"divsufsort";1:SuffixArraySkew
      select (objtype) {
          when "str" {
              // To be checked, I am not sure if this formula can estimate the total memory requirement
              // Lengths + 2*segs + 2*vals (copied to SymTab)
              overMemLimit(8*size + 16*size + nBytes);

              //allocate an offset array
              var sasoff = offsegs;
              //allocate an values array
              var sasval:[0..(nBytes-1)] int;
              //              var lcpval:[0..(nBytes-1)] int; now we will not build the LCP array at the same time

              var i:int;
              var j:int;
              forall i in 0..(size-1) do {
              // the start position of ith string in value array

                var startposition:int;
                var endposition:int;
                startposition = offsegs[i];
                endposition = startposition+length[i]-1;
                // what we do in the select structure is filling the sasval array with correct index
                select (algorithmNum) {
                    when 1 {
                       var sasize=length[i]:int;
                       ref strArray=strings.values.a[startposition..endposition];
                       var tmparray:[0..sasize+2] int;
                       var intstrArray:[0..sasize+2] int;
                       var x:int;
                       var y:int;
                       forall (x,y) in zip ( intstrArray[0..sasize-1],
                                strings.values.a[startposition..endposition]) do x=y;
                       intstrArray[sasize]=0;
                       intstrArray[sasize+1]=0;
                       intstrArray[sasize+2]=0;
                       SuffixArraySkew(intstrArray,tmparray,sasize,256);
                       for (x, y) in zip(sasval[startposition..endposition], tmparray[0..sasize-1]) do
                               x = y;
                    }
                    when 2 {
                       var sasize=length[i]:int(32);
                       var localstrArray:[0..endposition-startposition] uint(8);
                       var a:int(8);
                       var b:int(8);
                       ref strArray=strings.values.a[startposition..endposition];
                       localstrArray=strArray;
                       //for all (a,b) in zip (localstrArray[0..sasize-1],strArray) do a=b;
                       var tmparray:[1..sasize] int(32);
                       divsufsort(localstrArray,tmparray,sasize);
                       //divsufsort(strArray,tmparray,sasize);
                       var x:int;
                       var y:int(32);
                       for (x, y) in zip(sasval[startposition..endposition], tmparray[1..sasize]) do
                            x = y;
                    }
                }

/*
// Here we calculate the lcp(Longest Common Prefix) array value
                forall j in startposition+1..endposition do{
                        var tmpcount=0:int;
                        var tmpbefore=sasval[j-1]:int;
                        var tmpcur=sasval[j]:int;
                        var tmplen=min(sasize-tmpcur, sasize-tmpbefore);
                        var tmpi:int;
                        for tmpi in 0..tmplen-1 do {
                            if (intstrArray[tmpbefore]!=intstrArray[tmpcur]) {
                                 break;
                            }                        
                            tmpcount+=1;
                        } 
                        lcpval[j]=tmpcount;
                }
*/
              }
              var segName2 = st.nextName();
              var valName2 = st.nextName();
              //              var lcpvalName = st.nextName();

              var segEntry = new shared SymEntry(sasoff);
              var valEntry = new shared SymEntry(sasval);
              //              var lcpvalEntry = new shared SymEntry(lcpval);
              /*
              valEntry.enhancedInfo=lcpvalName;
              lcpvalEntry.enhancedInfo=valName2;
              we have removed enchancedInfo.
              */
              st.addEntry(segName2, segEntry);
              st.addEntry(valName2, valEntry);
//              st.addEntry(lcpvalName, lcpvalEntry);
              repMsg = 'created ' + st.attrib(segName2) + '+created ' + st.attrib(valName2);
              smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
              return new MsgTuple(repMsg, MsgType.NORMAL);

          }
          otherwise {
              var errorMsg = notImplementedError(pn, "("+objtype+")");
              writeln(generateErrorContext(
                                     msg=errorMsg, 
                                     lineNumber=getLineNumber(), 
                                     moduleName=getModuleName(), 
                                     routineName=getRoutineName(), 
                                     errorClass="NotImplementedError")); 
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);            
          }
      }

  }

  proc segLCPMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
      var (objtype, segName1, valName1,segName2,valName2) = payload.splitMsgToTuple(5);
      var repMsg: string;

      // check to make sure symbols defined
      st.check(segName1);
      st.check(valName1);
      st.check(segName2);
      st.check(valName2);

      var suffixarrays = new owned SegSArray(segName1, valName1, st);
      var size=suffixarrays.size;
      var nBytes = suffixarrays.nBytes;
      var length=suffixarrays.getLengths();
      var offsegs = (+ scan length) - length;


      //var strings = new owned SegString(segName2, valName2, st);
      var strings = getSegString(segName2, valName2, st);

      select (objtype) {
          when "int" {
              // To be checked, I am not sure if this formula can estimate the total memory requirement
              // Lengths + 2*segs + 2*vals (copied to SymTab)
              overMemLimit(8*size + 16*size + nBytes);

              //allocate an offset array
              var sasoff = offsegs;
              //allocate an values array
              var lcpval:[0..(nBytes-1)] int;

              var i:int;
              var j:int;
              forall i in 0..(size-1) do {
              // the start position of ith surrix array  in value array
                var startposition:int;
                var endposition:int;
                startposition = offsegs[i];
                endposition = startposition+length[i]-1;

                var sasize=length[i]:int;
                ref sufArray=suffixarrays.values.a[startposition..endposition];
                ref strArray=strings.values.a[startposition..endposition];
// Here we calculate the lcp(Longest Common Prefix) array value
                forall j in startposition+1..endposition do{
                        var tmpcount=0:int;
                        var tmpbefore=sufArray[j-1]:int;
                        var tmpcur=sufArray[j]:int;
                        var tmplen=min(sasize-tmpcur, sasize-tmpbefore);
                        var tmpi:int;
                        for tmpi in 0..tmplen-1 do {
                            if (strArray[tmpbefore]!=strArray[tmpcur]) {
                                 break;
                            }                        
                            tmpbefore+=1;
                            tmpcur+=1;
                            tmpcount+=1;
                        } 
                        lcpval[j]=tmpcount;
                }
              }
              var lcpsegName = st.nextName();
              var lcpvalName = st.nextName();

              var lcpsegEntry = new shared SymEntry(sasoff);
              var lcpvalEntry = new shared SymEntry(lcpval);
              /*
              valEntry.enhancedInfo=lcpvalName;
              lcpvalEntry.enhancedInfo=valName2;
              we have removed enchancedInfo.
              */
              st.addEntry(lcpsegName, lcpsegEntry);
              st.addEntry(lcpvalName, lcpvalEntry);
              repMsg = 'created ' + st.attrib(lcpsegName) + '+created ' + st.attrib(lcpvalName);
              smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
              return new MsgTuple(repMsg, MsgType.NORMAL);


          }
          otherwise {
              var errorMsg = notImplementedError(pn, "("+objtype+")");
              writeln(generateErrorContext(
                                     msg=errorMsg, 
                                     lineNumber=getLineNumber(), 
                                     moduleName=getModuleName(), 
                                     routineName=getRoutineName(), 
                                     errorClass="NotImplementedError")); 
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);            
          }
      }

  }

// directly read a string from given file and generate its suffix array
  proc segSAFileMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var pn = Reflection.getRoutineName();
//      var (FileName) = payload.decode().splitMsgToTuple(1);
      var FileName = payload;
      var repMsg: string;

//      var filesize:int(32);
      var filesize:int;
      var f = open(FileName, iomode.r);
      var size=1:int;
      var nBytes = f.size;
      var length:[0..0] int  =nBytes;
      var offsegs:[0..0] int =0 ;

      var sasize=nBytes:int;
      var startposition:int;
      var endposition:int;
      startposition = 0;
      endposition = nBytes-1;
      var strArray:[startposition..endposition]uint(8);
      var r = f.reader(kind=ionative);
      r.read(strArray);
      r.close();

      var segName = st.nextName();
      var valName = st.nextName();

      var segEntry = new shared SymEntry(offsegs);
      var valEntry = new shared SymEntry(strArray);
      st.addEntry(segName, segEntry);
      st.addEntry(valName, valEntry);

      var algorithmNum=2:int; //2:"divsufsort";1:SuffixArraySkew

      select ("str") {
          when "str" {
              // To be checked, I am not sure if this formula can estimate the total memory requirement
              // Lengths + 2*segs + 2*vals (copied to SymTab)
              overMemLimit(8*size + 16*size + nBytes);

              //allocate an offset array
              var sasoff = offsegs;
              //allocate a suffix array  values array and lcp array
              var sasval:[0..(nBytes-1)] int;
//              var lcpval:[0..(nBytes-1)] int;

              var i:int;
              forall i in 0..(size-1) do {
              // the start position of ith string in value array
                select (algorithmNum) {
                    when 1 {
                       var sasize=length[i]:int;
                       var tmparray:[0..sasize+2] int;
                       var intstrArray:[0..sasize+2] int;
                       var x:int;
                       var y:int;
                       forall (x,y) in zip ( intstrArray[0..sasize-1],strArray[startposition..endposition]) do x=y;
                       intstrArray[sasize]=0;
                       intstrArray[sasize+1]=0;
                       intstrArray[sasize+2]=0;
                       SuffixArraySkew(intstrArray,tmparray,sasize,256);
                       for (x, y) in zip(sasval[startposition..endposition], tmparray[0..sasize-1]) do
                               x = y;
                    }
                    when 2 {
                       var sasize=length[i]:int(32);
                       //ref strArray=strings.values.a[startposition..endposition];
                       var tmparray:[1..sasize] int(32);
                       divsufsort(strArray,tmparray,sasize);
                       var x:int;
                       var y:int(32);
                       for (x, y) in zip(sasval[startposition..endposition], tmparray[1..sasize]) do
                            x = y;
                    }
                }// end of select 
              } // end of forall
              var segName2 = st.nextName();
              var valName2 = st.nextName();
//              var lcpvalName = st.nextName();

              var segEntry = new shared SymEntry(sasoff);
              var valEntry = new shared SymEntry(sasval);
//              var lcpvalEntry = new shared SymEntry(lcpval);
              /*
              valEntry.enhancedInfo=lcpvalName;
              lcpvalEntry.enhancedInfo=valName2;
              We have removed enhancedInfo.
              */
              st.addEntry(segName2, segEntry);
              st.addEntry(valName2, valEntry);
//              st.addEntry(lcpvalName, lcpvalEntry);
              repMsg = 'created ' + st.attrib(segName2) + '+created ' + st.attrib(valName2) 
                        + '+created ' + st.attrib(segName) + '+created ' + st.attrib(valName);
              smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
              return new MsgTuple(repMsg, MsgType.NORMAL);

          }
          otherwise {
              var errorMsg = notImplementedError(pn, "("+FileName+")");
              writeln(generateErrorContext(
                                     msg=errorMsg, 
                                     lineNumber=getLineNumber(), 
                                     moduleName=getModuleName(), 
                                     routineName=getRoutineName(), 
                                     errorClass="NotImplementedError")); 
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);      
              return new MsgTuple(errorMsg, MsgType.ERROR);            
          }
      }

  }




// directly read a graph from given file and build the SegGraph class in memory
  //proc segGraphFileMsg(cmd: string, payload: bytes, st: borrowed SymTab): MsgTuple throws {
  proc segGraphFileMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      //var pn = Reflection.getRoutineName();
      var (NeS,NvS,ColS,DirectedS, FileName,RCMs) = payload.splitMsgToTuple(6);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      var RCMFlag=RCMs:int;
      if NumCol>2 {
           weighted=1;
      }

      timer.start();
      var src=makeDistArray(Ne,int);
      var dst=makeDistArray(Ne,int);
      var neighbour=makeDistArray(Nv,int);
      var start_i=makeDistArray(Nv,int);
      var depth=makeDistArray(Nv,int);

      var e_weight = makeDistArray(Ne,int);
      var v_weight = makeDistArray(Nv,int);

      var iv=makeDistArray(Ne,int);

      var srcR=makeDistArray(Ne,int);
      var dstR=makeDistArray(Ne,int);
      var neighbourR=makeDistArray(Nv,int);
      var start_iR=makeDistArray(Nv,int);
      ref  ivR=iv;

      var linenum=0:int;

      var repMsg: string;

      var startpos, endpos:int;
      var sort_flag:int;
      var filesize:int;

      proc readLinebyLine() throws {
           coforall loc in Locales  {
              on loc {
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var srclocal=src.localSubdomain();
                  var dstlocal=dst.localSubdomain();
                  var ewlocal=e_weight.localSubdomain();

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            if ewlocal.contains(curline){
                                e_weight[curline]=c:int;
                            }
                      }
                      if srclocal.contains(curline) {
                          src[curline]=a:int;
                          dst[curline]=b:int;
                      }
                      //if dstlocal.contains(curline) {
                      //    dst[curline]=b:int;
                      //}
                      curline+=1;
                  } 
                  //forall i in src.localSubdomain() {
                  //     src[i]=src[i]+(src[i]==dst[i]);
                  //     src[i]=src[i]%Nv;
                  //     dst[i]=dst[i]%Nv;
                  //}
                  forall i in start_i.localSubdomain()  {
                       start_i[i]=-1;
                  }
                  forall i in neighbour.localSubdomain()  {
                       neighbour[i]=0;
                  }
                  forall i in start_iR.localSubdomain()  {
                       start_iR[i]=-1;
                  }
                  forall i in neighbourR.localSubdomain()  {
                       neighbourR[i]=0;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
      }//end readLinebyLine
      

      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=Ne: int;

             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  2 { 
                      iv = mergedArgsort( 2); 
                 }
                 if (totalDigits >  2) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32) {    
                      return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             if (weighted){
                tmpedges=e_weight[iv];
                e_weight=tmpedges;
             }

             return "success";
      }//end combine_sort


      proc RCM() throws {
            
          var cmary: [0..Nv-1] int;
          var indexary:[0..Nv-1] int;
          depth=-1;
          proc smallVertex() :int {
                var tmpmindegree=1000000:int;
                var minindex=0:int;
                for i in 0..Nv-1 {
                   if (neighbour[i]<tmpmindegree) && (neighbour[i]>0) {
                      tmpmindegree=neighbour[i];
                      minindex=i;
                   }
                }
                return minindex;
          }

          var currentindex=0:int;
          var x=smallVertex();
          cmary[0]=x;
          depth[x]=0;

          //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(x);
          var numCurF=1:int;
          var GivenRatio=0.021:int;
          var topdown=0:int;
          var bottomup=0:int;
          var LF=1:int;
          var cur_level=0:int;
          
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }
                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           forall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) ) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                           }//end coforall
                       }else {// bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                //numCurF=SetNextF.getSize();
                numCurF=SetNextF.size;

                if (numCurF>0) {
                    var tmpary:[0..numCurF-1] int;
                    var sortary:[0..numCurF-1] int;
                    var numary:[0..numCurF-1] int;
                    var tmpa=0:int;
                    forall (a,b)  in zip (tmpary,SetNextF.toArray()) {
                        a=b;
                    }
                    forall i in 0..numCurF-1 {
                         numary[i]=neighbour[tmpary[i]];
                    }

                    var tmpiv = argsortDefault(numary);
                    sortary=tmpary[tmpiv];
                    cmary[currentindex+1..currentindex+numCurF]=sortary;
                    currentindex=currentindex+numCurF;
                }


                //SetCurF<=>SetNextF;
                SetCurF=SetNextF;
                SetNextF.clear();
          }//end while  

          if (currentindex+1<Nv) {
                 forall i in 0..Nv-1 with (+reduce currentindex) {
                     if depth[i]==-1 {
                       cmary[currentindex+1]=i;
                       currentindex+=1;  
                     }
                 }
          }
          cmary.reverse();
          forall i in 0..Nv-1{
              indexary[cmary[i]]=i;
          }

          var tmpary:[0..Ne-1] int;
          forall i in 0..Ne-1 {
                  tmpary[i]=indexary[src[i]];
          }
          src=tmpary;
          forall i in 0..Ne-1 {
                  tmpary[i]=indexary[dst[i]];
          }
          dst=tmpary;

          return "success";
      }//end RCM

      proc set_neighbour(){ 
          for i in 0..Ne-1 do {
             neighbour[src[i]]+=1;
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }

      readLinebyLine();
      timer.stop();

      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");

      timer.clear();
      timer.start();
      combine_sort();
      set_neighbour();

      if (directed==0) { //undirected graph

          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=Ne: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  2 { 
                      ivR = mergedArgsort( 2); 
                 }
                 if (totalDigits >  2) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }

             var tmpedges = srcR[ivR]; 
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";

          }// end combine_sortR


          proc set_neighbourR(){
             for i in 0..Ne-1 do {
                neighbourR[srcR[i]]+=1;
                if (start_iR[srcR[i]] ==-1){
                    start_iR[srcR[i]]=i;
                }
             }
          }
          proc RCM_u() throws {
            
              var cmary: [0..Nv-1] int;
              var indexary:[0..Nv-1] int;
              var depth:[0..Nv-1] int;
              depth=-1;
              proc smallVertex() :int {
                    var tmpmindegree=1000000:int;
                    var minindex=0:int;
                    for i in 0..Nv-1 {
                       if (neighbour[i]<tmpmindegree) && (neighbour[i]>0) {
                          tmpmindegree=neighbour[i];
                          minindex=i;
                       }
                    }
                    return minindex;
              }

              var currentindex=0:int;
              var x=smallVertex();
              cmary[0]=x;
              depth[x]=0;

              //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
              //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
              var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
              var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
              SetCurF.add(x);
              var numCurF=1:int;
              var GivenRatio=0.25:int;
              var topdown=0:int;
              var bottomup=0:int;
              var LF=1:int;
              var cur_level=0:int;
          
              while (numCurF>0) {
                    //writeln("SetCurF=");
                    //writeln(SetCurF);
                    coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                       on loc {
                           ref srcf=src;
                           ref df=dst;
                           ref nf=neighbour;
                           ref sf=start_i;

                           ref srcfR=srcR;
                           ref dfR=dstR;
                           ref nfR=neighbourR;
                           ref sfR=start_iR;

                           var edgeBegin=src.localSubdomain().low;
                           var edgeEnd=src.localSubdomain().high;
                           var vertexBegin=src[edgeBegin];
                           var vertexEnd=src[edgeEnd];
                           var vertexBeginR=srcR[edgeBegin];
                           var vertexEndR=srcR[edgeEnd];

                           proc xlocal(x :int, low:int, high:int):bool{
                                      if (low<=x && x<=high) {
                                          return true;
                                      } else {
                                          return false;
                                      }
                           }
                           var switchratio=(numCurF:real)/nf.size:real;
                           if (switchratio<GivenRatio) {//top down
                               topdown+=1;
                               forall i in SetCurF with (ref SetNextF) {
                                  if ((xlocal(i,vertexBegin,vertexEnd)) ) {// current edge has the vertex
                                      var    numNF=nf[i];
                                      var    edgeId=sf[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=df[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF){
                                             if (depth[j]==-1) {
                                                   depth[j]=cur_level+1;
                                                   SetNextF.add(j);
                                             }
                                      }
                                  } 
                                  if ((xlocal(i,vertexBeginR,vertexEndR)) )  {
                                      var    numNF=nfR[i];
                                      var    edgeId=sfR[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=dfR[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF)  {
                                             if (depth[j]==-1) {
                                                   depth[j]=cur_level+1;
                                                   SetNextF.add(j);
                                             }
                                      }
                                  }
                               }//end coforall
                           }else {// bottom up
                               bottomup+=1;
                               //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                               //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                               //   if depth[i]==-1 {
                               //      UnVisitedSet.add(i);
                               //   }
                               //}
                               forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                               //forall i in UnVisitedSet  with (ref SetNextF) {
                                  if depth[i]==-1 {
                                      var    numNF=nf[i];
                                      var    edgeId=sf[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=df[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF){
                                             if (SetCurF.contains(j)) {
                                                   depth[i]=cur_level+1;
                                                   SetNextF.add(i);
                                             }
                                      }

                                  }
                               }
                               //UnVisitedSet.clear();
                               //forall i in vertexBeginR..vertexEndR with (ref UnVisitedSet) {
                               //   if depth[i]==-1 {
                               //      UnVisitedSet.add(i);
                               //   }
                               //}
                               forall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                               //forall i in UnVisitedSet  with (ref SetNextF) {
                                  if depth[i]==-1 {
                                      var    numNF=nfR[i];
                                      var    edgeId=sfR[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=dfR[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF)  {
                                             if (SetCurF.contains(j)) {
                                                   depth[i]=cur_level+1;
                                                   SetNextF.add(i);
                                             }
                                      }
                                  }
                               }
                           }
                       }//end on loc
                    }//end coforall loc
                    cur_level+=1;
                    //numCurF=SetNextF.getSize();
                    numCurF=SetNextF.size;

                    if (numCurF>0) {
                        var tmpary:[0..numCurF-1] int;
                        var sortary:[0..numCurF-1] int;
                        var numary:[0..numCurF-1] int;
                        var tmpa=0:int;
                        forall (a,b)  in zip (tmpary,SetNextF.toArray()) {
                            a=b;
                        }
                        forall i in 0..numCurF-1 {
                             numary[i]=neighbour[tmpary[i]];
                        }

                        var tmpiv = argsortDefault(numary);
                        sortary=tmpary[tmpiv];
                        cmary[currentindex+1..currentindex+numCurF]=sortary;
                        currentindex=currentindex+numCurF;
                    }


                    //SetCurF<=>SetNextF;
                    SetCurF=SetNextF;
                    SetNextF.clear();
              }//end while  
              if (currentindex+1<Nv) {
                 forall i in 0..Nv-1 with(+reduce currentindex) {
                     if depth[i]==-1 {
                       cmary[currentindex+1]=i;
                       currentindex+=1;  
                     }
                 }
              }
              cmary.reverse();
              forall i in 0..Nv-1{
                  indexary[cmary[i]]=i;
              }
    
              var tmpary:[0..Ne-1] int;
              forall i in 0..Ne-1 {
                      tmpary[i]=indexary[src[i]];
              }
              src=tmpary;
              forall i in 0..Ne-1 {
                      tmpary[i]=indexary[dst[i]];
              }
              dst=tmpary;
 
              return "success";
          }//end RCM_u


          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          combine_sortR();
          set_neighbourR();

          if (RCMFlag>0) {
             RCM_u();
             neighbour=0;
             start_i=-1;
             combine_sort();
             set_neighbour();
             coforall loc in Locales  {
                  on loc {
                      forall i in srcR.localSubdomain(){
                            srcR[i]=dst[i];
                            dstR[i]=src[i];
                       }
                  }
              }
              neighbourR=0;
              start_iR=-1;
              combine_sortR();
              set_neighbourR();

          }   
      }//end of undirected
      else {

        if (RCMFlag>0) {
           RCM();
           neighbour=0;
           start_i=-1;
           combine_sort();
           set_neighbour();

        }

      }


      var ewName ,vwName:string;
      if (weighted!=0) {
        fillInt(v_weight,1,1000);
        //fillRandom(v_weight,0,100);
        ewName = st.nextName();
        vwName = st.nextName();
        var vwEntry = new shared SymEntry(v_weight);
        var ewEntry = new shared SymEntry(e_weight);
        st.addEntry(vwName, vwEntry);
        st.addEntry(ewName, ewEntry);
      }
      var srcName = st.nextName();
      var dstName = st.nextName();
      var startName = st.nextName();
      var neiName = st.nextName();
      var srcEntry = new shared SymEntry(src);
      var dstEntry = new shared SymEntry(dst);
      var startEntry = new shared SymEntry(start_i);
      var neiEntry = new shared SymEntry(neighbour);
      st.addEntry(srcName, srcEntry);
      st.addEntry(dstName, dstEntry);
      st.addEntry(startName, startEntry);
      st.addEntry(neiName, neiEntry);
      var sNv=Nv:string;
      var sNe=Ne:string;
      var sDirected=directed:string;
      var sWeighted=weighted:string;

      var srcNameR, dstNameR, startNameR, neiNameR:string;
      if (directed!=0) {//for directed graph
          if (weighted!=0) {// for weighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + '+ ' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) +
                    '+created ' + st.attrib(vwName)    + '+created ' + st.attrib(ewName);
          } else {// for unweighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + '+ ' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) ;

          }
      } else {//for undirected graph

          srcNameR = st.nextName();
          dstNameR = st.nextName();
          startNameR = st.nextName();
          neiNameR = st.nextName();
          var srcEntryR = new shared SymEntry(srcR);
          var dstEntryR = new shared SymEntry(dstR);
          var startEntryR = new shared SymEntry(start_iR);
          var neiEntryR = new shared SymEntry(neighbourR);
          st.addEntry(srcNameR, srcEntryR);
          st.addEntry(dstNameR, dstEntryR);
          st.addEntry(startNameR, startEntryR);
          st.addEntry(neiNameR, neiEntryR);
          if (weighted!=0) {// for weighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + ' +' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) +
                    '+created ' + st.attrib(srcNameR)   + '+created ' + st.attrib(dstNameR) +
                    '+created ' + st.attrib(startNameR) + '+created ' + st.attrib(neiNameR) +
                    '+created ' + st.attrib(vwName)    + '+created ' + st.attrib(ewName);
          } else {// for unweighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + ' +' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) +
                    '+created ' + st.attrib(srcNameR)   + '+created ' + st.attrib(dstNameR) +
                    '+created ' + st.attrib(startNameR) + '+created ' + st.attrib(neiNameR) ;
          }

      }
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }




// directly read a stream from given file and build the SegGraph class in memory
  proc segStreamFileMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var (NeS,NvS,ColS,DirectedS, FileName,FactorS) = payload.splitMsgToTuple(6);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var Factor=FactorS:int;
      var StreamNe=Ne/Factor:int;
      var StreamNv=Nv/Factor:int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      if NumCol>2 {
           weighted=1;
      }

      timer.start();
      var src=makeDistArray(StreamNe,int);
      var dst=makeDistArray(StreamNe,int);
      //var length=makeDistArray(StreamNv,int);
      var neighbour=makeDistArray(StreamNv,int);
      var start_i=makeDistArray(StreamNv,int);

      var e_weight = makeDistArray(StreamNe,int);
      var v_weight = makeDistArray(StreamNv,int);

      var iv=makeDistArray(StreamNe,int);

      var srcR=makeDistArray(StreamNe,int);
      var dstR=makeDistArray(StreamNe,int);
      var neighbourR=makeDistArray(StreamNv,int);
      var start_iR=makeDistArray(StreamNv,int);
      ref  ivR=iv;

      var linenum=0:int;

      var repMsg: string;

      var startpos, endpos:int;
      var sort_flag:int;
      var filesize:int;

      proc readLinebyLine() throws {
           coforall loc in Locales  {
              on loc {
                  var randv = new RandomStream(real, here.id, false);
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var Streamcurline=0:int;
                  var srclocal=src.localSubdomain();
                  var dstlocal=dst.localSubdomain();
                  var ewlocal=e_weight.localSubdomain();

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            if ewlocal.contains(Streamcurline){
                                e_weight[Streamcurline]=c:int;
                            }
                      }
                      if srclocal.contains(Streamcurline) {
                          //if ((curline<StreamNe) || (randv.getNext()< 1.0/Factor:real) ) {
                              src[Streamcurline]=(a:int) % StreamNv;
                              dst[Streamcurline]=(b:int) % StreamNv;
                          //}
                      }
                      curline+=1;
                      Streamcurline=curline%StreamNe;
                  } 
                  forall i in src.localSubdomain() {
                       src[i]=src[i]+(src[i]==dst[i]);
                       src[i]=src[i]%StreamNv;
                       dst[i]=dst[i]%StreamNv;
                  }
                  forall i in start_i.localSubdomain()  {
                       start_i[i]=-1;
                  }
                  forall i in neighbour.localSubdomain()  {
                       neighbour[i]=0;
                  }
                  forall i in start_iR.localSubdomain()  {
                       start_iR[i]=-1;
                  }
                  forall i in neighbourR.localSubdomain()  {
                       neighbourR[i]=0;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
      }//end readLinebyLine
      
      readLinebyLine();
      //start_i=-1;
      //start_iR=-1;
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      timer.start();

      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;

             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  4 { 
                      iv = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32) {    
                      return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             if (weighted){
                tmpedges=e_weight[iv];
                e_weight=tmpedges;
             }

             return "success";
      }//end combine_sort

      proc set_neighbour(){ 
          for i in 0..StreamNe-1 do {
             neighbour[src[i]]+=1;
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }

      combine_sort();
      set_neighbour();

      if (directed==0) { //undirected graph

          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  2 { 
                      ivR = mergedArgsort( 2); 
                 }
                 if (totalDigits >  2) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }

             var tmpedges = srcR[ivR]; 
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";

          }// end combine_sortR


          proc set_neighbourR(){
             for i in 0..StreamNe-1 do {
                neighbourR[srcR[i]]+=1;
                if (start_iR[srcR[i]] ==-1){
                    start_iR[srcR[i]]=i;
                }
             }
          }

          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          combine_sortR();
          set_neighbourR();

      }//end of undirected


      var ewName ,vwName:string;
      if (weighted!=0) {
        fillInt(v_weight,1,1000);
        //fillRandom(v_weight,0,100);
        ewName = st.nextName();
        vwName = st.nextName();
        var vwEntry = new shared SymEntry(v_weight);
        var ewEntry = new shared SymEntry(e_weight);
        st.addEntry(vwName, vwEntry);
        st.addEntry(ewName, ewEntry);
      }
      var srcName = st.nextName();
      var dstName = st.nextName();
      var startName = st.nextName();
      var neiName = st.nextName();
      var srcEntry = new shared SymEntry(src);
      var dstEntry = new shared SymEntry(dst);
      var startEntry = new shared SymEntry(start_i);
      var neiEntry = new shared SymEntry(neighbour);
      st.addEntry(srcName, srcEntry);
      st.addEntry(dstName, dstEntry);
      st.addEntry(startName, startEntry);
      st.addEntry(neiName, neiEntry);
      var sNv=StreamNv:string;
      var sNe=StreamNe:string;
      var sDirected=directed:string;
      var sWeighted=weighted:string;

      var srcNameR, dstNameR, startNameR, neiNameR:string;
      if (directed!=0) {//for directed graph
          if (weighted!=0) {// for weighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + '+ ' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) +
                    '+created ' + st.attrib(vwName)    + '+created ' + st.attrib(ewName);
          } else {// for unweighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + '+ ' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) ;

          }
      } else {//for undirected graph

          srcNameR = st.nextName();
          dstNameR = st.nextName();
          startNameR = st.nextName();
          neiNameR = st.nextName();
          var srcEntryR = new shared SymEntry(srcR);
          var dstEntryR = new shared SymEntry(dstR);
          var startEntryR = new shared SymEntry(start_iR);
          var neiEntryR = new shared SymEntry(neighbourR);
          st.addEntry(srcNameR, srcEntryR);
          st.addEntry(dstNameR, dstEntryR);
          st.addEntry(startNameR, startEntryR);
          st.addEntry(neiNameR, neiEntryR);
          if (weighted!=0) {// for weighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + ' +' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) +
                    '+created ' + st.attrib(srcNameR)   + '+created ' + st.attrib(dstNameR) +
                    '+created ' + st.attrib(startNameR) + '+created ' + st.attrib(neiNameR) +
                    '+created ' + st.attrib(vwName)    + '+created ' + st.attrib(ewName);
          } else {// for unweighted graph
              repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + ' +' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) +
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) +
                    '+created ' + st.attrib(srcNameR)   + '+created ' + st.attrib(dstNameR) +
                    '+created ' + st.attrib(startNameR) + '+created ' + st.attrib(neiNameR) ;
          }

      }
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }






  //proc segrmatgenMsg(cmd: string, payload: bytes, st: borrowed SymTab): MsgTuple throws {
  proc segrmatgenMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var repMsg: string;
      var (slgNv, sNe_per_v, sp, sdire,swei,RCMs )
          = payload.splitMsgToTuple(6);
      //writeln(slgNv, sNe_per_v, sp, sdire,swei,rest);
      var lgNv = slgNv: int;
      var Ne_per_v = sNe_per_v: int;
      var p = sp: real;
      var directed=sdire : int;
      var weighted=swei : int;
      var RCMFlag=RCMs : int;

      var Nv = 2**lgNv:int;
      // number of edges
      var Ne = Ne_per_v * Nv:int;

      var timer:Timer;
      timer.clear();
      timer.start();
      var n_vertices=Nv;
      var n_edges=Ne;
      var src=makeDistArray(Ne,int);
      var dst=makeDistArray(Ne,int);
      var neighbour=makeDistArray(Nv,int);
      var start_i=makeDistArray(Nv,int);
    
      var iv=makeDistArray(Ne,int);

      //var e_weight=makeDistArray(Nv,int);
      //var v_weight=makeDistArray(Nv,int);


      coforall loc in Locales  {
          on loc {
              forall i in src.localSubdomain() {
                  src[i]=1;
              }
              forall i in dst.localSubdomain() {
                  dst[i]=0;
              }
              forall i in start_i.localSubdomain() {
                  start_i[i]=-1;
              }
              forall i in neighbour.localSubdomain() {
                  neighbour[i]=0;
              }
          }
      }
      //start_i=-1;
      //neighbour=0;
      //src=1;
      //dst=1;
      var srcName:string ;
      var dstName:string ;
      var startName:string ;
      var neiName:string ;
      var sNv:string;
      var sNe:string;
      var sDirected:string;
      var sWeighted:string;


      proc rmat_gen() {
             var a = p;
             var b = (1.0 - a)/ 3.0:real;
             var c = b;
             var d = b;
             var ab=a+b;
             var c_norm = c / (c + d):real;
             var a_norm = a / (a + b):real;
             // generate edges
             //var src_bit=: [0..Ne-1]int;
             //var dst_bit: [0..Ne-1]int;
             var src_bit=src;
             var dst_bit=dst;

             for ib in 1..lgNv {
                 //var tmpvar: [0..Ne-1] real;
                 var tmpvar=src;
                 fillRandom(tmpvar);
                 coforall loc in Locales  {
                       on loc {
                           forall i in src_bit.localSubdomain() {
                                 src_bit[i]=tmpvar[i]>ab;
                           }       
                       }
                 }
                 //src_bit=tmpvar>ab;
                 fillRandom(tmpvar);
                 coforall loc in Locales  {
                       on loc {
                           forall i in dst_bit.localSubdomain() {
                                 dst_bit[i]=tmpvar[i]>(c_norm * src_bit[i] + a_norm * (~ src_bit[i]));
                           }       
                       }
                 }
                 //dst_bit=tmpvar>(c_norm * src_bit + a_norm * (~ src_bit));
                 coforall loc in Locales  {
                       on loc {
                           forall i in dst.localSubdomain() {
                                 dst[i]=dst[i]+ ((2**(ib-1)) * dst_bit[i]);
                           }       
                           forall i in src.localSubdomain() {
                                 src[i]=src[i]+ ((2**(ib-1)) * src_bit[i]);
                           }       
                       }
                 }
                 //src = src + ((2**(ib-1)) * src_bit);
                 //dst = dst + ((2**(ib-1)) * dst_bit);
             }
             coforall loc in Locales  {
                       on loc {
                           forall i in src_bit.localSubdomain() {
                                 src[i]=src[i]+(src[i]==dst[i]);
                                 src[i]=src[i]%Nv;
                                 dst[i]=dst[i]%Nv;
                           }       
                       }
             }
             //src=src%Nv;
             //dst=dst%Nv;

             //remove self loop
             //src=src+(src==dst);
             //src=src%Nv;
      }//end rmat_gen
      
      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=Ne: int;

             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  2 { 
                      iv = mergedArgsort( 2); 
                 }
                 if (totalDigits >  2) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32)  {
                       return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             // we need to change the weight order too to make them consistent 
             //if (weighted){
             //   tmpedges=e_weight[iv];
             //   e_weight=tmpedges;
             //}
             return "success";

      }//end combine_sort

      proc set_neighbour(){
             for i in 0..Ne-1 do {
                 neighbour[src[i]]+=1;
                 if (start_i[src[i]] ==-1){
                      start_i[src[i]]=i;
                      //writeln("assign index ",i, " to vertex ",src[i]);
                 }
             }
      }
      proc set_common_symtable(): string throws {
             srcName = st.nextName();
             dstName = st.nextName();
             startName = st.nextName();
             neiName = st.nextName();
             var srcEntry = new shared SymEntry(src);
             var dstEntry = new shared SymEntry(dst);
             var startEntry = new shared SymEntry(start_i);
             var neiEntry = new shared SymEntry(neighbour);
             st.addEntry(srcName, srcEntry);
             st.addEntry(dstName, dstEntry);
             st.addEntry(startName, startEntry);
             st.addEntry(neiName, neiEntry);
             sNv=Nv:string;
             sNe=Ne:string;
             sDirected=directed:string;
             sWeighted=weighted:string;
             return "success";
      }




      proc RCM() throws {
            
          var cmary: [0..Nv-1] int;
          var indexary:[0..Nv-1] int;
          var depth:[0..Nv-1] int;
          depth=-1;
          proc smallVertex() :int {
                var tmpmindegree=1000000:int;
                var minindex=0:int;
                for i in 0..Nv-1 {
                   if (neighbour[i]<tmpmindegree) && (neighbour[i]>0) {
                      tmpmindegree=neighbour[i];
                      minindex=i;
                   }
                }
                return minindex;
          }

          var currentindex=0:int;
          var x=smallVertex();
          cmary[0]=x;
          depth[x]=0;

          //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(x);
          var numCurF=1:int;
          var GivenRatio=0.021:int;
          var topdown=0:int;
          var bottomup=0:int;
          var LF=1:int;
          var cur_level=0:int;
          
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }
                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           forall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) ) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                           }//end coforall
                       }else {// bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                //numCurF=SetNextF.getSize();
                numCurF=SetNextF.size;

                if (numCurF>0) {
                    var tmpary:[0..numCurF-1] int;
                    var sortary:[0..numCurF-1] int;
                    var numary:[0..numCurF-1] int;
                    var tmpa=0:int;
                    forall (a,b)  in zip (tmpary,SetNextF.toArray()) {
                        a=b;
                    }
                    forall i in 0..numCurF-1 {
                         numary[i]=neighbour[tmpary[i]];
                    }

                    var tmpiv = argsortDefault(numary);
                    sortary=tmpary[tmpiv];
                    cmary[currentindex+1..currentindex+numCurF]=sortary;
                    currentindex=currentindex+numCurF;
                }


                //SetCurF<=>SetNextF;
                SetCurF=SetNextF;
                SetNextF.clear();
          }//end while  

          if (currentindex+1<Nv) {
                 forall i in 0..Nv-1 with (+reduce currentindex) {
                     if depth[i]==-1 {
                       cmary[currentindex+1]=i;
                       currentindex+=1;  
                     }
                 }
          }
          cmary.reverse();
          forall i in 0..Nv-1{
              indexary[cmary[i]]=i;
          }

          var tmpary:[0..Ne-1] int;
          forall i in 0..Ne-1 {
                  tmpary[i]=indexary[src[i]];
          }
          src=tmpary;
          forall i in 0..Ne-1 {
                  tmpary[i]=indexary[dst[i]];
          }
          dst=tmpary;

          return "success";
      }//end RCM


      if (directed!=0) {// for directed graph
          if (weighted!=0) { // for weighted graph
             //var e_weight: [0..Ne-1] int;
             //var v_weight: [0..Nv-1] int;
             var e_weight = makeDistArray(Ne,int);
             var v_weight = makeDistArray(Nv,int);
             rmat_gen();
             timer.stop();
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$$$$$$ RMAT generate the graph takes ",timer.elapsed(), "$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             timer.clear();
             timer.start();
             combine_sort();
             set_neighbour();


             if (RCMFlag>0) {
                    RCM();
                    neighbour=0;
                    start_i=-1;
                    combine_sort();
                    set_neighbour();
             }


             var ewName ,vwName:string;
             fillInt(e_weight,1,1000);
             //fillRandom(e_weight,0,100);
             fillInt(v_weight,1,1000);
             //fillRandom(v_weight,0,100);
             ewName = st.nextName();
             vwName = st.nextName();
             var vwEntry = new shared SymEntry(v_weight);
             var ewEntry = new shared SymEntry(e_weight);
             try! st.addEntry(vwName, vwEntry);
             try! st.addEntry(ewName, ewEntry);
      
             set_common_symtable();
             repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + '+ ' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) + 
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) + 
                    '+created ' + st.attrib(vwName)    + '+created ' + st.attrib(ewName);

          } else {
             rmat_gen();
             timer.stop();
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$$$$$$ RMAT generate the graph takes ",timer.elapsed(), "$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             timer.clear();
             timer.start();
             //twostep_sort();
             combine_sort();
             set_neighbour();

             if (RCMFlag>0) {
                    RCM();
                    neighbour=0;
                    start_i=-1;
                    combine_sort();
                    set_neighbour();
             }

             set_common_symtable();
             repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + '+ ' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) + 
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) ; 
          }
      }// end for directed graph
      else {
          // only for undirected graph, we only declare R variables here
          var srcR=makeDistArray(Ne,int);
          var dstR=makeDistArray(Ne,int);
          var neighbourR=makeDistArray(Nv,int);
          var start_iR=makeDistArray(Nv,int);
          ref  ivR=iv;



          proc RCM_u() throws {
            
              var cmary: [0..Nv-1] int;
              var indexary:[0..Nv-1] int;
              var depth:[0..Nv-1] int;
              depth=-1;
              proc smallVertex() :int {
                    var tmpmindegree=1000000:int;
                    var minindex=0:int;
                    for i in 0..Nv-1 {
                       if (neighbour[i]<tmpmindegree) && (neighbour[i]>0) {
                          tmpmindegree=neighbour[i];
                          minindex=i;
                       }
                    }
                    return minindex;
              }

              var currentindex=0:int;
              var x=smallVertex();
              cmary[0]=x;
              depth[x]=0;

              //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
              //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
              var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
              var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
              SetCurF.add(x);
              var numCurF=1:int;
              var GivenRatio=0.25:int;
              var topdown=0:int;
              var bottomup=0:int;
              var LF=1:int;
              var cur_level=0:int;
          
              while (numCurF>0) {
                    //writeln("SetCurF=");
                    //writeln(SetCurF);
                    coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                       on loc {
                           ref srcf=src;
                           ref df=dst;
                           ref nf=neighbour;
                           ref sf=start_i;

                           ref srcfR=srcR;
                           ref dfR=dstR;
                           ref nfR=neighbourR;
                           ref sfR=start_iR;

                           var edgeBegin=src.localSubdomain().low;
                           var edgeEnd=src.localSubdomain().high;
                           var vertexBegin=src[edgeBegin];
                           var vertexEnd=src[edgeEnd];
                           var vertexBeginR=srcR[edgeBegin];
                           var vertexEndR=srcR[edgeEnd];

                           proc xlocal(x :int, low:int, high:int):bool{
                                      if (low<=x && x<=high) {
                                          return true;
                                      } else {
                                          return false;
                                      }
                           }
                           var switchratio=(numCurF:real)/nf.size:real;
                           if (switchratio<GivenRatio) {//top down
                               topdown+=1;
                               forall i in SetCurF with (ref SetNextF) {
                                  if ((xlocal(i,vertexBegin,vertexEnd)) ) {// current edge has the vertex
                                      var    numNF=nf[i];
                                      var    edgeId=sf[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=df[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF){
                                             if (depth[j]==-1) {
                                                   depth[j]=cur_level+1;
                                                   SetNextF.add(j);
                                             }
                                      }
                                  } 
                                  if ((xlocal(i,vertexBeginR,vertexEndR)) )  {
                                      var    numNF=nfR[i];
                                      var    edgeId=sfR[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=dfR[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF)  {
                                             if (depth[j]==-1) {
                                                   depth[j]=cur_level+1;
                                                   SetNextF.add(j);
                                             }
                                      }
                                  }
                               }//end coforall
                           }else {// bottom up
                               bottomup+=1;
                               //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                               //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                               //   if depth[i]==-1 {
                               //      UnVisitedSet.add(i);
                               //   }
                               //}
                               forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                               //forall i in UnVisitedSet  with (ref SetNextF) {
                                  if depth[i]==-1 {
                                      var    numNF=nf[i];
                                      var    edgeId=sf[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=df[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF){
                                             if (SetCurF.contains(j)) {
                                                   depth[i]=cur_level+1;
                                                   SetNextF.add(i);
                                             }
                                      }

                                  }
                               }
                               //UnVisitedSet.clear();
                               //forall i in vertexBeginR..vertexEndR with (ref UnVisitedSet) {
                               //   if depth[i]==-1 {
                               //      UnVisitedSet.add(i);
                               //   }
                               //}
                               forall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                               //forall i in UnVisitedSet  with (ref SetNextF) {
                                  if depth[i]==-1 {
                                      var    numNF=nfR[i];
                                      var    edgeId=sfR[i];
                                      var nextStart=max(edgeId,edgeBegin);
                                      var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                      ref NF=dfR[nextStart..nextEnd];
                                      forall j in NF with (ref SetNextF)  {
                                             if (SetCurF.contains(j)) {
                                                   depth[i]=cur_level+1;
                                                   SetNextF.add(i);
                                             }
                                      }
                                  }
                               }
                           }
                       }//end on loc
                    }//end coforall loc
                    cur_level+=1;
                    //numCurF=SetNextF.getSize();
                    numCurF=SetNextF.size;

                    if (numCurF>0) {
                        var tmpary:[0..numCurF-1] int;
                        var sortary:[0..numCurF-1] int;
                        var numary:[0..numCurF-1] int;
                        var tmpa=0:int;
                        forall (a,b)  in zip (tmpary,SetNextF.toArray()) {
                            a=b;
                        }
                        forall i in 0..numCurF-1 {
                             numary[i]=neighbour[tmpary[i]];
                        }

                        var tmpiv = argsortDefault(numary);
                        sortary=tmpary[tmpiv];
                        cmary[currentindex+1..currentindex+numCurF]=sortary;
                        currentindex=currentindex+numCurF;
                    }


                    //SetCurF<=>SetNextF;
                    SetCurF=SetNextF;
                    SetNextF.clear();
              }//end while  
              if (currentindex+1<Nv) {
                 forall i in 0..Nv-1 with (+reduce currentindex) {
                     if depth[i]==-1 {
                       cmary[currentindex+1]=i;
                       currentindex+=1;  
                     }
                 }
              }
              cmary.reverse();
              forall i in 0..Nv-1{
                  indexary[cmary[i]]=i;
              }
    
              var tmpary:[0..Ne-1] int;
              forall i in 0..Ne-1 {
                      tmpary[i]=indexary[src[i]];
              }
              src=tmpary;
              forall i in 0..Ne-1 {
                      tmpary[i]=indexary[dst[i]];
              }
              dst=tmpary;
 
              return "success";
          }//end RCM_u



          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          coforall loc in Locales  {
              on loc {
                           forall i in start_iR.localSubdomain() {
                                 start_iR[i]=-1;
                           }       
                           forall i in neighbourR.localSubdomain() {
                                 neighbourR[i]=0;
                           }       
              }
          }
          //start_iR=-1;
          //lengthR=0;
          //neighbourR=0;
          var srcNameR, dstNameR, startNameR, neiNameR:string;
        
          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=Ne: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  2 { 
                      ivR = mergedArgsort( 2); 
                 }
                 if (totalDigits >  2) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=srcR[ivR];
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";
             

          }// end combine_sortR

          proc    set_neighbourR(){
             for i in 0..Ne-1 do {
                neighbourR[srcR[i]]+=1;
                if (start_iR[srcR[i]] ==-1){
                    start_iR[srcR[i]]=i;
                }
             }
          }

          proc   set_common_symtableR():string throws {
          //proc   set_common_symtableR() {
             srcNameR = st.nextName();
             dstNameR = st.nextName();
             startNameR = st.nextName();
             neiNameR = st.nextName();
             var srcEntryR = new shared SymEntry(srcR);
             var dstEntryR = new shared SymEntry(dstR);
             var startEntryR = new shared SymEntry(start_iR);
             var neiEntryR = new shared SymEntry(neighbourR);
             st.addEntry(srcNameR, srcEntryR);
             st.addEntry(dstNameR, dstEntryR);
             st.addEntry(startNameR, startEntryR);
             st.addEntry(neiNameR, neiEntryR);
             return "success";
          }


          if (weighted!=0) {
             rmat_gen();
             timer.stop();
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$$$$$$ RMAT graph generating takes ",timer.elapsed(), "$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             timer.clear();
             timer.start();
             combine_sort();
             set_neighbour();


             coforall loc in Locales  {
                       on loc {
                           forall i in srcR.localSubdomain() {
                                 srcR[i]=dst[i];
                                 dstR[i]=src[i];
                           }       
                       }
             }
             //srcR = dst;
             //dstR = src;
             //twostep_sortR(); 
             combine_sortR();
             set_neighbourR();

             if (RCMFlag>0) {
                    RCM_u();
                    neighbour=0;
                    start_i=-1;
                    combine_sort();
                    set_neighbour();
                    coforall loc in Locales  {
                              on loc {
                                  forall i in srcR.localSubdomain() {
                                        srcR[i]=dst[i];
                                        dstR[i]=src[i];
                                  }       
                              }
                    }
                    neighbourR=0;
                    start_iR=-1;
                    combine_sortR();
                    set_neighbourR();

             }
             //only for weighted  graph
             var ewName ,vwName:string;
             var e_weight = makeDistArray(Ne,int);
             var v_weight = makeDistArray(Nv,int);
             //var e_weight: [0..Ne-1] int;
             //var v_weight: [0..Nv-1] int;

             fillInt(e_weight,1,1000);
             //fillRandom(e_weight,0,100);
             fillInt(v_weight,1,1000);
             //fillRandom(v_weight,0,100);
             ewName = st.nextName();
             vwName = st.nextName();
             var vwEntry = new shared SymEntry(v_weight);
             var ewEntry = new shared SymEntry(e_weight);
             st.addEntry(vwName, vwEntry);
             st.addEntry(ewName, ewEntry);
             // end of weighted!=0
      
             set_common_symtable();
             set_common_symtableR();
 
             repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + ' +' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) + 
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) + 
                    '+created ' + st.attrib(srcNameR)   + '+created ' + st.attrib(dstNameR) + 
                    '+created ' + st.attrib(startNameR) + '+created ' + st.attrib(neiNameR) + 
                    '+created ' + st.attrib(vwName)    + '+created ' + st.attrib(ewName);


          } else {

             rmat_gen();
             timer.stop();
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$$$$$$ RMAT graph generating takes ",timer.elapsed(), "$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
             timer.clear();
             timer.start();
             //twostep_sort();
             combine_sort();
             set_neighbour();


             coforall loc in Locales  {
                       on loc {
                           forall i in srcR.localSubdomain() {
                                 srcR[i]=dst[i];
                                 dstR[i]=src[i];
                           }       
                       }
             }
             combine_sortR();
             set_neighbourR();
             if (RCMFlag>0) {
                    RCM_u();
                    neighbour=0;
                    start_i=-1;
                    combine_sort();
                    set_neighbour();
                    coforall loc in Locales  {
                              on loc {
                                  forall i in srcR.localSubdomain() {
                                        srcR[i]=dst[i];
                                        dstR[i]=src[i];
                                  }       
                              }
                    }
                    neighbourR=0;
                    start_iR=-1;
                    combine_sortR();
                    set_neighbourR();

             }

             set_common_symtable();
             set_common_symtableR();
             repMsg =  sNv + '+ ' + sNe + '+ ' + sDirected + ' +' + sWeighted +
                    '+created ' + st.attrib(srcName)   + '+created ' + st.attrib(dstName) + 
                    '+created ' + st.attrib(startName) + '+created ' + st.attrib(neiName) + 
                    '+created ' + st.attrib(srcNameR)   + '+created ' + st.attrib(dstNameR) + 
                    '+created ' + st.attrib(startNameR) + '+created ' + st.attrib(neiNameR) ; 


          }// end unweighted graph
      }// end undirected graph
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$$$$$$ sorting RMAT graph takes ",timer.elapsed(), "$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);      
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }




  //proc segBFSMsg(cmd: string, payload: bytes, st: borrowed SymTab): MsgTuple throws {
  proc segBFSMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var repMsg: string;
      //var (n_verticesN,n_edgesN,directedN,weightedN,srcN, dstN, startN, neighbourN,vweightN,eweightN, rootN )
      //    = payload.decode().splitMsgToTuple(10);
      var (RCMs,n_verticesN,n_edgesN,directedN,weightedN,restpart )
          = payload.splitMsgToTuple(6);
      var Nv=n_verticesN:int;
      var Ne=n_edgesN:int;
      var Directed=directedN:int;
      var Weighted=weightedN:int;
      var depthName:string;
      var RCMFlag=RCMs:int;
      var timer:Timer;
      timer.start();
      var depth=makeDistArray(Nv,int);
      coforall loc in Locales  {
                  on loc {
                           forall i in depth.localSubdomain() {
                                 depth[i]=-1;
                           }       
                  }
      }
      //var depth=-1: [0..Nv-1] int;
      var root:int;
      var srcN, dstN, startN, neighbourN,vweightN,eweightN, rootN :string;
      var srcRN, dstRN, startRN, neighbourRN:string;
       


      proc _d1_bfs_kernel(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int):string throws{
          var cur_level=0;
          var numCurF=1:int;//flag for stopping loop


          var edgeBeginG=makeDistArray(numLocales,int);//each locale's starting edge ID
          var edgeEndG=makeDistArray(numLocales,int);//each locales'ending edge ID

          var vertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var vertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var HvertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var HvertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var TvertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var TvertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src


          var localNum=makeDistArray(numLocales,int);// current locales's local access times
          var remoteNum=makeDistArray(numLocales,int);// current locales's remote access times
          localNum=0;
          remoteNum=0;

          var MaxBufSize=makeDistArray(numLocales,int);//temp array to calculate global max
          coforall loc in Locales   {
              on loc {
                 edgeBeginG[here.id]=src.localSubdomain().low;
                 edgeEndG[here.id]=src.localSubdomain().high;

                 vertexBeginG[here.id]=src[edgeBeginG[here.id]];
                 vertexEndG[here.id]=src[edgeEndG[here.id]];

                 if (here.id>0) {
                   HvertexBeginG[here.id]=vertexEndG[here.id-1];
                 } else {
                   HvertexBeginG[here.id]=-1;
                 }
                 if (here.id<numLocales-1) {
                   TvertexEndG[here.id]=vertexBeginG[here.id+1];
                 } else {
                   TvertexEndG[here.id]=nei.size;
                 }

                 MaxBufSize[here.id]=vertexEndG[here.id]-vertexBeginG[here.id]+1;
              }
          }
          var CMaxSize=1: int;
          for i in 0..numLocales-1 {
              if   MaxBufSize[i]> CMaxSize {
                   CMaxSize=MaxBufSize[i];
              }
          }
          //writeln("CMaxSize=",CMaxSize);
          var localArrayG=makeDistArray(numLocales*CMaxSize,int);//current frontier elements
          //var localArrayNG=makeDistArray(numLocales*CMaxSize,int);// next frontier in the same locale
          //var sendArrayG=makeDistArray(numLocales*CMaxSize,int);// next frontier in other locales
          var recvArrayG=makeDistArray(numLocales*numLocales*CMaxSize,int);//hold the current frontier elements
          var LPG=makeDistArray(numLocales,int);// frontier pointer to current position
          //var LPNG=makeDistArray(numLocales,int);// next frontier pointer to current position
          //var SPG=makeDistArray(numLocales,int);// receive buffer
          var RPG=makeDistArray(numLocales*numLocales,int);//pointer to the current position can receive element
          LPG=0;
          //LPNG=0;
          //SPG=0;
          RPG=0;

          proc xlocal(x :int, low:int, high:int):bool{
                     if (low<=x && x<=high) {
                            return true;
                     } else {
                            return false;
                     }
          }

          proc xremote(x :int, low:int, high:int):bool{
                     if (low>=x || x>=high) {
                            return true;
                     } else {
                            return false;
                     }
          }
          coforall loc in Locales   {
              on loc {
                 if (xlocal(root,vertexBeginG[here.id],vertexEndG[here.id]) ) {
                   localArrayG[CMaxSize*here.id]=root;
                   LPG[here.id]=1;
                   //writeln("1 Add root=",root," into locale ",here.id);
                 }
              }
          }

          while numCurF >0 {
              coforall loc in Locales   {
                  on loc {
                   ref srcf=src;
                   ref df=dst;
                   ref nf=nei;
                   ref sf=start_i;

                   //var aggdst= newDstAggregator(int);
                   //var aggsrc= newSrcAggregator(int);
                   var LocalSet= new set(int,parSafe = true);//use set to keep the next local frontier, 
                                                             //vertex in src or srcR
                   var RemoteSet=new set(int,parSafe = true);//use set to keep the next remote frontier

                   var mystart=here.id*CMaxSize;//start index 
                   //writeln("1-1 my locale=",here.id, ",has ", LPG[here.id], " elements=",localArrayG[mystart..mystart+LPG[here.id]-1],",startposition=",mystart);
                   coforall i in localArrayG[mystart..mystart+LPG[here.id]-1] with (ref LocalSet, ref RemoteSet)  {
                            // each locale just processes its local vertices
                              if xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) {
                                  // i in src, current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                                    //writeln("2 My locale=", here.id," Add ", j, " into local");
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                                    //writeln("3 My locale=", here.id," Add ", j, " into remote");
                                               }
                                         }
                                  }
                              } 
                       
                              if (RemoteSet.size>0) {//there is vertex to be sent
                                  remoteNum[here.id]+=RemoteSet.size;
                                  //writeln("6-0 My locale=", here.id," there are remote element =",RemoteSet);
                                  coforall localeNum in 0..numLocales-1  { 
                                         var ind=0:int;
                                         //for k in RemoteSet with ( +reduce ind) (var agg= newDstAggregator(int)) {
                                         var agg= newDstAggregator(int); 
                                         for k in RemoteSet {
                                                //writeln("6-2 My locale=", here.id," test remote element ", k);
                                                if (xlocal(k,vertexBeginG[localeNum],vertexEndG[localeNum])){
                                                     agg.copy(recvArrayG[localeNum*numLocales*CMaxSize+
                                                                         here.id*CMaxSize+ind] ,k);
                                                     ind+=1;
                                                     
                                                     //writeln("6 My locale=", here.id,"send", k, "to locale= ",localeNum," number=", ind, " send element=", recvArrayG[localeNum*numLocales*CMaxSize+ here.id*CMaxSize+ind-1]);
                                                }
                                         }
                                         RPG[localeNum*numLocales+here.id]=ind;
                                         ind=0;
                                  }
                              }//end if
                   }//end coforall
                   LPG[here.id]=0;
                   if LocalSet.size>0 {
                       LPG[here.id]=LocalSet.size;
                       localNum[here.id]+=LocalSet.size;
                       var mystart=here.id*CMaxSize;
                       forall (a,b)  in zip (localArrayG[mystart..mystart+LocalSet.size-1],LocalSet.toArray()) {
                              //writeln("7-0 My locale=", here.id,"  a=",a, " b=",b);
                              a=b;
                       }
                       var tmp=0;
                       for i in LocalSet {
                              //writeln("7-1 My locale=", here.id,"  element i=",i," tmp=",tmp);
                              //localArrayG[mystart+tmp]=i;
                              //writeln("7-2 My locale=", here.id,"  local array [tmp]=",localArrayG[mystart+tmp]," tmp=",tmp);
                              tmp+=1;
                       }
                       //writeln("7 My locale=", here.id,"  local set=",LocalSet, "to local array and size= ",LocalSet.size, " local array=",localArrayG[mystart..mystart+LocalSet.size-1]);
                   }
                   LocalSet.clear();
                   RemoteSet.clear();
                   //LPNG[here.id]=0;
                  }//end on loc
              }//end coforall loc
              coforall loc in Locales {
                  on loc {
                   var mystart=here.id*CMaxSize;
                   for i in 0..numLocales-1 {
                       if (RPG[numLocales*i+here.id]>0) {
                           localArrayG[mystart+LPG[here.id]-1..mystart+LPG[here.id]+RPG[numLocales*i+here.id]-2]=
                               recvArrayG[CMaxSize*numLocales*i+here.id*CMaxSize..
                                          CMaxSize*numLocales*i+here.id*CMaxSize+RPG[numLocales*i+here.id]-1];
                           LPG[here.id]=LPG[here.id]+RPG[numLocales*i+here.id];
                           //writeln("8 My locale=", here.id," after colloect array=",localArrayG[mystart..mystart+LPG[here.id]-1]);
                       }
                         
                   }
                  }//end on loc
              }//end coforall loc
              numCurF=0;
              //writeln("10-0 LPG=",LPG);
              for iL in 0..(numLocales-1)  {
                   if LPG[iL] >0 {
                       //writeln("10  locale ",iL, " has ",LPG[iL], " elements");
                       numCurF=1;
                       break;
                   }
              }
              RPG=0;
              cur_level+=1;
              //writeln("cur level=",cur_level);
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          var TotalLocal=0:int;
          var TotalRemote=0:int;
          for i in 0..numLocales-1 {
            TotalLocal+=localNum[i];
            TotalRemote+=remoteNum[i];
          }
          writeln("Local Ratio=", (TotalLocal):real/(TotalLocal+TotalRemote):real,"Total Local Access=",TotalLocal," , Total Remote Access=",TotalRemote);
          return "success";
      }//end of_d1_bfs_kernel


      proc _d1_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var cur_level=0;
          var numCurF=1:int;//flag for stopping loop


          var edgeBeginG=makeDistArray(numLocales,int);//each locale's starting edge ID
          var edgeEndG=makeDistArray(numLocales,int);//each locales'ending edge ID

          var vertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var vertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var HvertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var HvertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var TvertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var TvertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src

          var vertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var vertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR
          var HvertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var HvertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR
          var TvertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var TvertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR

          var localNum=makeDistArray(numLocales,int);// current locales's local access times
          var remoteNum=makeDistArray(numLocales,int);// current locales's remote access times
          localNum=0;
          remoteNum=0;

          var MaxBufSize=makeDistArray(numLocales,int);//temp array to calculate global max
          coforall loc in Locales   {
              on loc {
                 edgeBeginG[here.id]=src.localSubdomain().low;
                 edgeEndG[here.id]=src.localSubdomain().high;

                 vertexBeginG[here.id]=src[edgeBeginG[here.id]];
                 vertexEndG[here.id]=src[edgeEndG[here.id]];

                 vertexBeginRG[here.id]=srcR[edgeBeginG[here.id]];
                 vertexEndRG[here.id]=srcR[edgeEndG[here.id]];
                 if (here.id>0) {
                   HvertexBeginG[here.id]=vertexEndG[here.id-1];
                   HvertexBeginRG[here.id]=vertexEndRG[here.id-1];
                 } else {
                   HvertexBeginG[here.id]=-1;
                   HvertexBeginRG[here.id]=-1;
                 }
                 if (here.id<numLocales-1) {
                   TvertexEndG[here.id]=vertexBeginG[here.id+1];
                   TvertexEndRG[here.id]=vertexBeginRG[here.id+1];
                 } else {
                   TvertexEndG[here.id]=nei.size;
                   TvertexEndRG[here.id]=nei.size;
                 }

                 MaxBufSize[here.id]=vertexEndG[here.id]-vertexBeginG[here.id]+
                                     vertexEndRG[here.id]-vertexBeginRG[here.id]+2;
              }
          }
          var CMaxSize=1: int;
          for i in 0..numLocales-1 {
              if   MaxBufSize[i]> CMaxSize {
                   CMaxSize=MaxBufSize[i];
              }
          }
          //writeln("CMaxSize=",CMaxSize);
          var localArrayG=makeDistArray(numLocales*CMaxSize,int);//current frontier elements
          //var localArrayNG=makeDistArray(numLocales*CMaxSize,int);// next frontier in the same locale
          //var sendArrayG=makeDistArray(numLocales*CMaxSize,int);// next frontier in other locales
          var recvArrayG=makeDistArray(numLocales*numLocales*CMaxSize,int);//hold the current frontier elements
          var LPG=makeDistArray(numLocales,int);// frontier pointer to current position
          //var LPNG=makeDistArray(numLocales,int);// next frontier pointer to current position
          //var SPG=makeDistArray(numLocales,int);// receive buffer
          var RPG=makeDistArray(numLocales*numLocales,int);//pointer to the current position can receive element
          LPG=0;
          //LPNG=0;
          //SPG=0;
          RPG=0;

          proc xlocal(x :int, low:int, high:int):bool{
                     if (low<=x && x<=high) {
                            return true;
                     } else {
                            return false;
                     }
          }

          proc xremote(x :int, low:int, high:int):bool{
                     if (low>=x || x>=high) {
                            return true;
                     } else {
                            return false;
                     }
          }
          coforall loc in Locales   {
              on loc {
                 if (xlocal(root,vertexBeginG[here.id],vertexEndG[here.id]) || 
                                 xlocal(root,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                   localArrayG[CMaxSize*here.id]=root;
                   LPG[here.id]=1;
                   //writeln("1 Add root=",root," into locale ",here.id);
                 }
              }
          }

          while numCurF >0 {
              coforall loc in Locales   {
                  on loc {
                   ref srcf=src;
                   ref df=dst;
                   ref nf=nei;
                   ref sf=start_i;

                   ref srcfR=srcR;
                   ref dfR=dstR;
                   ref nfR=neiR;
                   ref sfR=start_iR;


                   //var aggdst= newDstAggregator(int);
                   //var aggsrc= newSrcAggregator(int);
                   var LocalSet= new set(int,parSafe = true);//use set to keep the next local frontier, 
                                                             //vertex in src or srcR
                   var RemoteSet=new set(int,parSafe = true);//use set to keep the next remote frontier

                   var mystart=here.id*CMaxSize;//start index 
                   //writeln("1-1 my locale=",here.id, ",has ", LPG[here.id], " elements=",localArrayG[mystart..mystart+LPG[here.id]-1],",startposition=",mystart);
                   coforall i in localArrayG[mystart..mystart+LPG[here.id]-1] with (ref LocalSet, ref RemoteSet)  {
                            // each locale just processes its local vertices
                              if xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) {
                                  // i in src, current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(j,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                                    //writeln("2 My locale=", here.id," Add ", j, " into local");
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(j,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                                    //writeln("3 My locale=", here.id," Add ", j, " into remote");
                                               }
                                         }
                                  }
                              } 
                              if xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(j,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                                    //writeln("4 reverse My locale=", here.id,"Add ", j, "into local");
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(j,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                                    //writeln("5 reverse My locale=", here.id,"Add ", j, "into remote");
                                               }
                                         }
                                  }
                              }
                       
                              if (RemoteSet.size>0) {//there is vertex to be sent
                                  remoteNum[here.id]+=RemoteSet.size;
                                  //writeln("6-0 My locale=", here.id," there are remote element =",RemoteSet);
                                  coforall localeNum in 0..numLocales-1  { 
                                         var ind=0:int;
                                         //for k in RemoteSet with ( +reduce ind) (var agg= newDstAggregator(int)) {
                                         var agg= newDstAggregator(int); 
                                         for k in RemoteSet {
                                                //writeln("6-2 My locale=", here.id," test remote element ", k);
                                                if (xlocal(k,vertexBeginG[localeNum],vertexEndG[localeNum])||
                                                    xlocal(k,vertexBeginRG[localeNum],vertexEndRG[localeNum])){
                                                     agg.copy(recvArrayG[localeNum*numLocales*CMaxSize+
                                                                         here.id*CMaxSize+ind] ,k);
                                                     ind+=1;
                                                     
                                                     //writeln("6 My locale=", here.id,"send", k, "to locale= ",localeNum," number=", ind, " send element=", recvArrayG[localeNum*numLocales*CMaxSize+ here.id*CMaxSize+ind-1]);
                                                }
                                         }
                                         RPG[localeNum*numLocales+here.id]=ind;
                                         ind=0;
                                  }
                              }//end if
                   }//end coforall
                   LPG[here.id]=0;
                   if LocalSet.size>0 {
                       LPG[here.id]=LocalSet.size;
                       localNum[here.id]+=LocalSet.size;
                       var mystart=here.id*CMaxSize;
                       forall (a,b)  in zip (localArrayG[mystart..mystart+LocalSet.size-1],LocalSet.toArray()) {
                              //writeln("7-0 My locale=", here.id,"  a=",a, " b=",b);
                              a=b;
                       }
                       var tmp=0;
                       for i in LocalSet {
                              //writeln("7-1 My locale=", here.id,"  element i=",i," tmp=",tmp);
                              //localArrayG[mystart+tmp]=i;
                              //writeln("7-2 My locale=", here.id,"  local array [tmp]=",localArrayG[mystart+tmp]," tmp=",tmp);
                              tmp+=1;
                       }
                       //writeln("7 My locale=", here.id,"  local set=",LocalSet, "to local array and size= ",LocalSet.size, " local array=",localArrayG[mystart..mystart+LocalSet.size-1]);
                   }
                   LocalSet.clear();
                   RemoteSet.clear();
                   //LPNG[here.id]=0;
                  }//end on loc
              }//end coforall loc
              coforall loc in Locales {
                  on loc {
                   var mystart=here.id*CMaxSize;
                   for i in 0..numLocales-1 {
                       if (RPG[numLocales*i+here.id]>0) {
                           localArrayG[mystart+LPG[here.id]-1..mystart+LPG[here.id]+RPG[numLocales*i+here.id]-2]=
                               recvArrayG[CMaxSize*numLocales*i+here.id*CMaxSize..
                                          CMaxSize*numLocales*i+here.id*CMaxSize+RPG[numLocales*i+here.id]-1];
                           LPG[here.id]=LPG[here.id]+RPG[numLocales*i+here.id];
                           //writeln("8 My locale=", here.id," after colloect array=",localArrayG[mystart..mystart+LPG[here.id]-1]);
                       }
                         
                   }
                  }//end on loc
              }//end coforall loc
              numCurF=0;
              //writeln("10-0 LPG=",LPG);
              for iL in 0..(numLocales-1)  {
                   if LPG[iL] >0 {
                       //writeln("10  locale ",iL, " has ",LPG[iL], " elements");
                       numCurF=1;
                       break;
                   }
              }
              RPG=0;
              cur_level+=1;
              //writeln("cur level=",cur_level);
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          var TotalLocal=0:int;
          var TotalRemote=0:int;
          for i in 0..numLocales-1 {
            TotalLocal+=localNum[i];
            TotalRemote+=remoteNum[i];
          }
          writeln("Local Ratio=", (TotalLocal):real/(TotalLocal+TotalRemote):real,"Total Local Access=",TotalLocal," , Total Remote Access=",TotalRemote);
          return "success";
      }//end of _d1_bfs_kernel_u

      proc fo_bag_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int, 
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          //var SetCurF: domain(int);//use domain to keep the current frontier
          //var SetNextF:domain(int);//use domain to keep the next frontier
          var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          //var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          //var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;
          var topdown=0:int;
          var bottomup=0:int;
          //var GivenRatio=0.22:int;
          //writeln("THE GIVEN RATIO IS ");
          //writeln(GivenRatio);

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];
                       var vertexBeginR=srcR[edgeBegin];
                       var vertexEndR=srcR[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }
                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           forall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) || (LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                              if ((xlocal(i,vertexBeginR,vertexEndR)) || (LF==0))  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF)  {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              }
                           }//end coforall
                       }else {// bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                           //UnVisitedSet.clear();
                           //forall i in vertexBeginR..vertexEndR with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF)  {
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }
                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                numCurF=SetNextF.getSize();
                //numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                //SetCurF=SetNextF;
                //SetCurF.clear();
                SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$number of top down = ",topdown, " number of bottom up=", bottomup,"$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of fo_bag_bfs_kernel_u


      proc fo_bag_bfs_kernel(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          //var SetCurF: domain(int);//use domain to keep the current frontier
          //var SetNextF:domain(int);//use domain to keep the next frontier
          var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          //var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          //var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;
          var topdown=0:int;
          var bottomup=0:int;

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;


                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }
                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           forall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) || (LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                           }//end coforall
                       }else {// bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                numCurF=SetNextF.getSize();
                //numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                //SetCurF=SetNextF;
                //SetCurF.clear();
                SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$number of top down = ",topdown, " number of bottom up=", bottomup,"$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of fo_bag_bfs_kernel


      proc fo_set_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int, 
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          //var SetCurF: domain(int);//use domain to keep the current frontier
          //var SetNextF:domain(int);//use domain to keep the next frontier
          //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;
          var topdown=0:int;
          var bottomup=0:int;

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];
                       var vertexBeginR=srcR[edgeBegin];
                       var vertexEndR=srcR[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }

                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           forall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) ||( LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                              if ((xlocal(i,vertexBeginR,vertexEndR)) ||(LF==0))  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF)  {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              }
                           }//end coforall
                       }else {//bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                           //UnVisitedSet.clear();
                           //forall i in vertexBeginR..vertexEndR with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF)  {
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }
                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                //numCurF=SetNextF.getSize();
                numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                SetCurF=SetNextF;
                //SetCurF.clear();
                //SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$number of top down = ",topdown, " number of bottom up=", bottomup,"$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of fo_set_bfs_kernel_u




      proc fo_domain_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int, 
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          var SetCurF: domain(int);//use domain to keep the current frontier
          var SetNextF:domain(int);//use domain to keep the next frontier
          //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          //var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          //var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;
          var topdown=0:int;
          var bottomup=0:int;

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];
                       var vertexBeginR=srcR[edgeBegin];
                       var vertexEndR=srcR[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }

                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           forall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) ||( LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                              if ((xlocal(i,vertexBeginR,vertexEndR)) || (LF==0))  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF)  {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              }
                           }//end coforall
                       } else {//bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                           //UnVisitedSet.clear();
                           //forall i in vertexBeginR..vertexEndR with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           forall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                           //forall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  forall j in NF with (ref SetNextF)  {
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }
                              }
                           }

                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                //numCurF=SetNextF.getSize();
                numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                SetCurF=SetNextF;
                //SetCurF.clear();
                //SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$number of top down = ",topdown, " number of bottom up=", bottomup,"$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of fo_domain_bfs_kernel_u



      proc fo_d1_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int,GivenRatio:real):string throws{
          var cur_level=0;
          var numCurF=1:int;//flag for stopping loop
          var topdown=0:int;
          var bottomup=0:int;


          var edgeBeginG=makeDistArray(numLocales,int);//each locale's starting edge ID
          var edgeEndG=makeDistArray(numLocales,int);//each locales'ending edge ID

          var vertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var vertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var HvertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var TvertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var BoundBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var BoundEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src

          var vertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var vertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR
          var HvertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var TvertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR

          var localNum=makeDistArray(numLocales,int);// current locales's local access times
          var remoteNum=makeDistArray(numLocales,int);// current locales's remote access times
          localNum=0;
          remoteNum=0;

          var MaxBufSize=makeDistArray(numLocales,int);//temp array to calculate global max
          coforall loc in Locales with (+ reduce topdown, + reduce bottomup)  {
              on loc {
                 edgeBeginG[here.id]=src.localSubdomain().low;
                 edgeEndG[here.id]=src.localSubdomain().high;

                 vertexBeginG[here.id]=src[edgeBeginG[here.id]];
                 vertexEndG[here.id]=src[edgeEndG[here.id]];

                 vertexBeginRG[here.id]=srcR[edgeBeginG[here.id]];
                 vertexEndRG[here.id]=srcR[edgeEndG[here.id]];

                 BoundBeginG[here.id]=vertexBeginG[here.id];
                 BoundEndG[here.id]=vertexEndG[here.id];

                 if (here.id>0) {
                   HvertexBeginG[here.id]=vertexEndG[here.id-1];
                   HvertexBeginRG[here.id]=vertexEndRG[here.id-1];
                   BoundBeginG[here.id]=min(vertexEndG[here.id-1]+1,nei.size-1);
              
                 } else {
                   HvertexBeginG[here.id]=-1;
                   HvertexBeginRG[here.id]=-1;
                   BoundBeginG[here.id]=0;
                 }
                 if (here.id<numLocales-1) {
                   TvertexEndG[here.id]=vertexBeginG[here.id+1];
                   TvertexEndRG[here.id]=vertexBeginRG[here.id+1];
                   BoundEndG[here.id]=max(BoundBeginG[here.id+1]-1,0);
                 } else {
                   TvertexEndG[here.id]=nei.size;
                   TvertexEndRG[here.id]=nei.size;
                   BoundEndG[here.id]=nei.size-1;
                 }

                 MaxBufSize[here.id]=vertexEndG[here.id]-vertexBeginG[here.id]+
                                     vertexEndRG[here.id]-vertexBeginRG[here.id]+2;
              }
          }
          var CMaxSize=1: int;
          for i in 0..numLocales-1 {
              if   MaxBufSize[i]> CMaxSize {
                   CMaxSize=MaxBufSize[i];
              }
          }
          var localArrayG=makeDistArray(numLocales*CMaxSize,int);//current frontier elements
          //var localArrayNG=makeDistArray(numLocales*CMaxSize,int);// next frontier in the same locale
          //var sendArrayG=makeDistArray(numLocales*CMaxSize,int);// next frontier in other locales
          var recvArrayG=makeDistArray(numLocales*numLocales*CMaxSize,int);//hold the current frontier elements
          var LPG=makeDistArray(numLocales,int);// frontier pointer to current position
          //var LPNG=makeDistArray(numLocales,int);// next frontier pointer to current position
          //var SPG=makeDistArray(numLocales,int);// receive buffer
          var RPG=makeDistArray(numLocales*numLocales,int);//pointer to the current position can receive element
          LPG=0;
          //LPNG=0;
          //SPG=0;
          RPG=0;

          proc xlocal(x :int, low:int, high:int):bool{
                     if (low<=x && x<=high) {
                            return true;
                     } else {
                            return false;
                     }
          }

          proc xremote(x :int, low:int, high:int):bool{
                     if (low>=x || x>=high) {
                            return true;
                     } else {
                            return false;
                     }
          }
          coforall loc in Locales   {
              on loc {
                 if (xlocal(root,vertexBeginG[here.id],vertexEndG[here.id]) || 
                                 xlocal(root,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                   localArrayG[CMaxSize*here.id]=root;
                   LPG[here.id]=1;
                 }
              }
          }

          while numCurF >0 {
              coforall loc in Locales with (+ reduce bottomup, + reduce topdown)   {
                  on loc {
                   ref srcf=src;
                   ref df=dst;
                   ref nf=nei;
                   ref sf=start_i;

                   ref srcfR=srcR;
                   ref dfR=dstR;
                   ref nfR=neiR;
                   ref sfR=start_iR;


                   //var aggdst= newDstAggregator(int);
                   //var aggsrc= newSrcAggregator(int);
                   var LocalSet= new set(int,parSafe = true);//use set to keep the next local frontier, 
                                                             //vertex in src or srcR
                   var RemoteSet=new set(int,parSafe = true);//use set to keep the next remote frontier

                   var mystart=here.id*CMaxSize;//start index 



                   var   switchratio=(numCurF:real)/nf.size:real;
                   if (switchratio<GivenRatio) {//top down
                       topdown+=1;
                       forall i in localArrayG[mystart..mystart+LPG[here.id]-1] 
                                                   with (ref LocalSet, ref RemoteSet)  {
                            // each locale just processes its local vertices
                              if xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) {
                                  // i in src, current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  forall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(j,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(j,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                               }
                                         }
                                  }
                              } 
                              if xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(j,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(j,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                               }
                                         }
                                  }
                              }
                       }//end coforall
                       
                       if (RemoteSet.size>0) {//there is vertex to be sent
                                  remoteNum[here.id]+=RemoteSet.size;
                                  coforall localeNum in 0..numLocales-1  { 
                                       if localeNum != here.id{
                                         var ind=0:int;
                                         //for k in RemoteSet with ( +reduce ind) (var agg= newDstAggregator(int)) {
                                         var agg= newDstAggregator(int); 
                                         for k in RemoteSet {
                                                if (xlocal(k,vertexBeginG[localeNum],vertexEndG[localeNum])||
                                                    xlocal(k,vertexBeginRG[localeNum],vertexEndRG[localeNum])){
                                                     agg.copy(recvArrayG[localeNum*numLocales*CMaxSize+
                                                                         here.id*CMaxSize+ind] ,k);
                                                     //recvArrayG[localeNum*numLocales*CMaxSize+
                                                     //                    here.id*CMaxSize+ind]=k;
                                                     ind+=1;
                                                     
                                                }
                                         }
                                         agg.flush();
                                         RPG[localeNum*numLocales+here.id]=ind;
                                         ind=0;
                                       }
                                  }
                              }//end if
                   }// end of top down
                   else {  //bottom up
                       bottomup+=1;
                       //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                       //forall i in BoundBeginG[here.id]..BoundEndG[here.id] with (ref UnVisitedSet) {
                       //       if depth[i]==-1 {
                       //          UnVisitedSet.add(i);
                       //       }
                       //}
                       proc FrontierHas(x:int):bool{
                            var returnval=false;
                            coforall i in 0..numLocales-1 with (ref returnval) {
                                if (xlocal(x,vertexBeginG[i],vertexEndG[i]) ||
                                    xlocal(x,vertexBeginRG[i],vertexEndRG[i])) {
                                    var mystart=i*CMaxSize;
                                    forall j in localArrayG[mystart..mystart+LPG[i]-1] with (ref returnval){
                                         if j==x {
                                            returnval=true;
                                         }
                                    }
                                }
                            }
                            return returnval;
                       }

                       forall i in BoundBeginG[here.id]..BoundEndG[here.id]
                                                   with (ref LocalSet, ref RemoteSet)  {
                       //forall i in UnVisitedSet  with (ref LocalSet, ref RemoteSet)  {
                          if (depth[i]==-1) {
                              if xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if FrontierHas(j) {
                                               depth[i]=cur_level+1;
                                               if (xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    LocalSet.add(i);
                                               } 
                                               if (xremote(i,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(i,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    RemoteSet.add(i);
                                               }
                                         }
                                  }
                              } 
                              if xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if FrontierHas(j) {
                                               depth[i]=cur_level+1;
                                               if (xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    LocalSet.add(i);
                                               } 
                                               if (xremote(i,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(i,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    RemoteSet.add(i);
                                               }
                                         }
                                  }
                              }
                          } //end if (depth[i]==-1)
                       
                       }//end coforall
                   }//end bottom up
                   if (RemoteSet.size>0) {//there is vertex to be sent
                                  remoteNum[here.id]+=RemoteSet.size;
                                  coforall localeNum in 0..numLocales-1  { 
                                       if localeNum != here.id{
                                         var ind=0:int;
                                         var agg= newDstAggregator(int); 
                                         for k in RemoteSet {
                                                if (xlocal(k,vertexBeginG[localeNum],vertexEndG[localeNum])||
                                                    xlocal(k,vertexBeginRG[localeNum],vertexEndRG[localeNum])){
                                                     agg.copy(recvArrayG[localeNum*numLocales*CMaxSize+
                                                                         here.id*CMaxSize+ind] ,k);
                                                     ind+=1;
                                                     
                                                }
                                         }
                                         agg.flush();
                                         RPG[localeNum*numLocales+here.id]=ind;
                                         ind=0;
                                       }
                                  }
                   }//end if

                   localNum[here.id]+=LPG[here.id];
                   LPG[here.id]=0;
                   if LocalSet.size>0 {
                       LPG[here.id]=LocalSet.size;
                       localNum[here.id]+=LocalSet.size;
                       var mystart=here.id*CMaxSize;
                       forall (a,b)  in zip (localArrayG[mystart..mystart+LocalSet.size-1],LocalSet.toArray()) {
                              a=b;
                       }
                   }
                   LocalSet.clear();
                   RemoteSet.clear();
                   //LPNG[here.id]=0;
                  }//end on loc
              }//end coforall loc
              coforall loc in Locales {
                  on loc {
                   var mystart=here.id*CMaxSize;
                   for i in 0..numLocales-1 {
                     if i != here.id {
                       if (RPG[here.id*numLocales+i]>0) {
                           localArrayG[mystart+LPG[here.id]..mystart+LPG[here.id]+RPG[numLocales*here.id+i]-1]=
                           recvArrayG[CMaxSize*numLocales*here.id+i*CMaxSize..
                                      CMaxSize*numLocales*here.id+i*CMaxSize+RPG[numLocales*here.id+i]-1];
                           LPG[here.id]=LPG[here.id]+RPG[numLocales*here.id+i];
                       }
                     }
                         
                   }
                  }//end on loc
              }//end coforall loc
              numCurF=0;
              for iL in 0..(numLocales-1)  {
                   if LPG[iL] >0 {
                       //numCurF=1;
                       numCurF+=LPG[iL];
                       //break;
                   }
              }
              RPG=0;
              cur_level+=1;
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$number of top-down = ", topdown, " number of bottom-up=",bottomup, "$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          var TotalLocal=0:int;
          var TotalRemote=0:int;
          for i in 0..numLocales-1 {
            TotalLocal+=localNum[i];
            TotalRemote+=remoteNum[i];
          }
          writeln("Local Ratio=", (TotalLocal):real/(TotalLocal+TotalRemote):real,"Total Local Access=",TotalLocal," , Total Remote Access=",TotalRemote);
          return "success";
      }//end of fo_d1_bfs_kernel_u


      proc co_bag_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int, 
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          //var SetCurF: domain(int);//use domain to keep the current frontier
          //var SetNextF:domain(int);//use domain to keep the next frontier
          var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          //var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          //var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;
          var bottomup=0:int;
          var topdown=0:int;

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];
                       var vertexBeginR=srcR[edgeBegin];
                       var vertexEndR=srcR[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }
                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           coforall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) || (LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                              if ((xlocal(i,vertexBeginR,vertexEndR)) || (LF==0))  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF)  {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              }
                           }//end coforall
                       }else {// bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd  with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}

                           //coforall i in UnVisitedSet with (ref SetNextF) {
                           coforall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                           //UnVisitedSet.clear();
                           //forall i in vertexBeginR..vertexEndR  with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           coforall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                           //coforall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF)  {
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }
                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                numCurF=SetNextF.getSize();
                //numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                //SetCurF=SetNextF;
                //SetCurF.clear();
                SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$number of top-down = ", topdown, " number of bottom-up=",bottomup, "$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of co_bag_bfs_kernel_u




      proc co_set_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int, 
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          //var SetCurF: domain(int);//use domain to keep the current frontier
          //var SetNextF:domain(int);//use domain to keep the next frontier
          //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;

          var bottomup=0:int;
          var topdown=0:int;

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];
                       var vertexBeginR=srcR[edgeBegin];
                       var vertexEndR=srcR[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }

                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           coforall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) ||( LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                              if ((xlocal(i,vertexBeginR,vertexEndR)) ||(LF==0))  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF)  {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              }
                           }//end coforall
                       }else {//bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd  with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           coforall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //coforall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                           //UnVisitedSet.clear();
                           //forall i in vertexBeginR..vertexEndR  with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           coforall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                           //coforall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF)  {
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }
                              }
                           }
                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                //numCurF=SetNextF.getSize();
                numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                SetCurF=SetNextF;
                //SetCurF.clear();
                //SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$number of top-down = ", topdown, " number of bottom-up=",bottomup, "$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of co_set_bfs_kernel_u




      proc co_domain_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int, 
                        LF:int,GivenRatio:real):string throws{
          var cur_level=0;
          var SetCurF: domain(int);//use domain to keep the current frontier
          var SetNextF:domain(int);//use domain to keep the next frontier
          //var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          //var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          //var SetCurF= new set(int,parSafe = true);//use set to keep the current frontier
          //var SetNextF=new set(int,parSafe = true);//use set to keep the next fromtier
          SetCurF.add(root);
          var numCurF=1:int;
          var bottomup=0:int;
          var topdown=0:int;

          //while (!SetCurF.isEmpty()) {
          while (numCurF>0) {
                //writeln("SetCurF=");
                //writeln(SetCurF);
                coforall loc in Locales  with (ref SetNextF,+ reduce topdown, + reduce bottomup) {
                   on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var edgeBegin=src.localSubdomain().low;
                       var edgeEnd=src.localSubdomain().high;
                       var vertexBegin=src[edgeBegin];
                       var vertexEnd=src[edgeEnd];
                       var vertexBeginR=srcR[edgeBegin];
                       var vertexEndR=srcR[edgeEnd];

                       proc xlocal(x :int, low:int, high:int):bool{
                                  if (low<=x && x<=high) {
                                      return true;
                                  } else {
                                      return false;
                                  }
                       }

                       var switchratio=(numCurF:real)/nf.size:real;
                       if (switchratio<GivenRatio) {//top down
                           topdown+=1;
                           coforall i in SetCurF with (ref SetNextF) {
                              if ((xlocal(i,vertexBegin,vertexEnd)) ||( LF==0)) {// current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF){
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              } 
                              if ((xlocal(i,vertexBeginR,vertexEndR)) || (LF==0))  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF)  {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               SetNextF.add(j);
                                         }
                                  }
                              }
                           }//end coforall
                       } else {//bottom up
                           bottomup+=1;
                           //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                           //forall i in vertexBegin..vertexEnd  with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           coforall i in vertexBegin..vertexEnd  with (ref SetNextF) {
                           //coforall i in UnVisitedSet with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF){
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }

                              }
                           }
                           //UnVisitedSet.clear();
                           //forall i in vertexBeginR..vertexEndR  with (ref UnVisitedSet) {
                           //   if depth[i]==-1 {
                           //      UnVisitedSet.add(i);
                           //   }
                           //}
                           coforall i in vertexBeginR..vertexEndR  with (ref SetNextF) {
                           //coforall i in UnVisitedSet  with (ref SetNextF) {
                              if depth[i]==-1 {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBegin);
                                  var nextEnd=min(edgeEnd,edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref SetNextF)  {
                                         if (SetCurF.contains(j)) {
                                               depth[i]=cur_level+1;
                                               SetNextF.add(i);
                                         }
                                  }
                              }
                           }

                       }
                   }//end on loc
                }//end coforall loc
                cur_level+=1;
                //numCurF=SetNextF.getSize();
                numCurF=SetNextF.size;
                //writeln("SetCurF= ", SetCurF, " SetNextF=", SetNextF, " level ", cur_level+1," numCurf=", numCurF);
                //numCurF=SetNextF.size;
                SetCurF=SetNextF;
                //SetCurF.clear();
                //SetCurF<=>SetNextF;
                SetNextF.clear();
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$number of top-down = ", topdown, " number of bottom-up=",bottomup, "$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          return "success";
      }//end of co_domain_bfs_kernel_u



      proc co_d1_bfs_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int,GivenRatio:real):string throws{
          var cur_level=0;
          var numCurF=1:int;//flag for stopping loop
          var topdown=0:int;
          var bottomup=0:int;


          var edgeBeginG=makeDistArray(numLocales,int);//each locale's starting edge ID
          var edgeEndG=makeDistArray(numLocales,int);//each locales'ending edge ID

          var vertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var vertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var HvertexBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var TvertexEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src
          var BoundBeginG=makeDistArray(numLocales,int);//each locale's beginning vertex ID in src
          var BoundEndG=makeDistArray(numLocales,int);// each locales' ending vertex ID in src

          var vertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var vertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR
          var HvertexBeginRG=makeDistArray(numLocales,int);// each locales' beginning vertex ID in srcR
          var TvertexEndRG=makeDistArray(numLocales,int);// each locales's ending vertex ID in srcR

          var localNum=makeDistArray(numLocales,int);// current locales's local access times
          var remoteNum=makeDistArray(numLocales,int);// current locales's remote access times
          localNum=0;
          remoteNum=0;

          var MaxBufSize=makeDistArray(numLocales,int);//temp array to calculate global max
          coforall loc in Locales   {
              on loc {
                 edgeBeginG[here.id]=src.localSubdomain().low;
                 edgeEndG[here.id]=src.localSubdomain().high;

                 vertexBeginG[here.id]=src[edgeBeginG[here.id]];
                 vertexEndG[here.id]=src[edgeEndG[here.id]];

                 vertexBeginRG[here.id]=srcR[edgeBeginG[here.id]];
                 vertexEndRG[here.id]=srcR[edgeEndG[here.id]];

                 BoundBeginG[here.id]=vertexBeginG[here.id];
                 BoundEndG[here.id]=vertexEndG[here.id];

                 if (here.id>0) {
                   HvertexBeginG[here.id]=vertexEndG[here.id-1];
                   HvertexBeginRG[here.id]=vertexEndRG[here.id-1];
                   BoundBeginG[here.id]=min(vertexEndG[here.id-1]+1,nei.size-1);
              
                 } else {
                   HvertexBeginG[here.id]=-1;
                   HvertexBeginRG[here.id]=-1;
                   BoundBeginG[here.id]=0;
                 }
                 if (here.id<numLocales-1) {
                   TvertexEndG[here.id]=vertexBeginG[here.id+1];
                   TvertexEndRG[here.id]=vertexBeginRG[here.id+1];
                   BoundEndG[here.id]=max(BoundBeginG[here.id+1]-1,0);
                 } else {
                   TvertexEndG[here.id]=nei.size;
                   TvertexEndRG[here.id]=nei.size;
                   BoundEndG[here.id]=nei.size-1;
                 }

                 MaxBufSize[here.id]=vertexEndG[here.id]-vertexBeginG[here.id]+
                                     vertexEndRG[here.id]-vertexBeginRG[here.id]+2;
              }
          }
          var CMaxSize=1: int;
          for i in 0..numLocales-1 {
              if   MaxBufSize[i]> CMaxSize {
                   CMaxSize=MaxBufSize[i];
              }
          }
          var localArrayG=makeDistArray(numLocales*CMaxSize,int);//current frontier elements
          //var localArrayNG=makeDistArray(numLocales*CMaxSize,int);// next frontier in the same locale
          //var sendArrayG=makeDistArray(numLocales*CMaxSize,int);// next frontier in other locales
          var recvArrayG=makeDistArray(numLocales*numLocales*CMaxSize,int);//hold the current frontier elements
          var LPG=makeDistArray(numLocales,int);// frontier pointer to current position
          //var LPNG=makeDistArray(numLocales,int);// next frontier pointer to current position
          //var SPG=makeDistArray(numLocales,int);// receive buffer
          var RPG=makeDistArray(numLocales*numLocales,int);//pointer to the current position can receive element
          LPG=0;
          //LPNG=0;
          //SPG=0;
          RPG=0;

          proc xlocal(x :int, low:int, high:int):bool{
                     if (low<=x && x<=high) {
                            return true;
                     } else {
                            return false;
                     }
          }

          proc xremote(x :int, low:int, high:int):bool{
                     if (low>=x || x>=high) {
                            return true;
                     } else {
                            return false;
                     }
          }
          coforall loc in Locales   {
              on loc {
                 if (xlocal(root,vertexBeginG[here.id],vertexEndG[here.id]) || 
                                 xlocal(root,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                   localArrayG[CMaxSize*here.id]=root;
                   LPG[here.id]=1;
                 }
              }
          }

          while numCurF >0 {
              coforall loc in Locales with (+ reduce topdown, + reduce bottomup)  {
                  on loc {
                   ref srcf=src;
                   ref df=dst;
                   ref nf=nei;
                   ref sf=start_i;

                   ref srcfR=srcR;
                   ref dfR=dstR;
                   ref nfR=neiR;
                   ref sfR=start_iR;


                   //var aggdst= newDstAggregator(int);
                   //var aggsrc= newSrcAggregator(int);
                   var LocalSet= new set(int,parSafe = true);//use set to keep the next local frontier, 
                                                             //vertex in src or srcR
                   var RemoteSet=new set(int,parSafe = true);//use set to keep the next remote frontier

                   var mystart=here.id*CMaxSize;//start index 



                   var   switchratio=(numCurF:real)/nf.size:real;
                   if (switchratio<GivenRatio) {//top down
                       topdown+=1;
                       coforall i in localArrayG[mystart..mystart+LPG[here.id]-1] 
                                                   with (ref LocalSet, ref RemoteSet)  {
                            // each locale just processes its local vertices
                              if xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) {
                                  // i in src, current edge has the vertex
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(j,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(j,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                               }
                                         }
                                  }
                              } 
                              if xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if (depth[j]==-1) {
                                               depth[j]=cur_level+1;
                                               if (xlocal(j,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(j,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    //localArrayNG[mystart+LPNG[here.id]]=j; 
                                                    //LPNG[here.id]+=1;
                                                    LocalSet.add(j);
                                               } 
                                               if (xremote(j,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(j,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    //sendArrayG[mystart+SPG[here.id]]=j;                 
                                                    //SPG[here.id]+=1;
                                                    RemoteSet.add(j);
                                               }
                                         }
                                  }
                              }
                       
                       }//end coforall
                       if (RemoteSet.size>0) {//there is vertex to be sent
                                  remoteNum[here.id]+=RemoteSet.size;
                                  coforall localeNum in 0..numLocales-1  { 
                                       if localeNum != here.id{
                                         var ind=0:int;
                                         //for k in RemoteSet with ( +reduce ind) (var agg= newDstAggregator(int)) {
                                         var agg= newDstAggregator(int); 
                                         for k in RemoteSet {
                                                if (xlocal(k,vertexBeginG[localeNum],vertexEndG[localeNum])||
                                                    xlocal(k,vertexBeginRG[localeNum],vertexEndRG[localeNum])){
                                                     agg.copy(recvArrayG[localeNum*numLocales*CMaxSize+
                                                                         here.id*CMaxSize+ind] ,k);
                                                     //recvArrayG[localeNum*numLocales*CMaxSize+
                                                     //                    here.id*CMaxSize+ind]=k;
                                                     ind+=1;
                                                     
                                                }
                                         }
                                         agg.flush();
                                         RPG[localeNum*numLocales+here.id]=ind;
                                         ind=0;
                                       }
                                  }
                       }//end if
                   }// end of top down
                   else {  //bottom up
                       bottomup+=1;
                       proc FrontierHas(x:int):bool{
                            var returnval=false;
                            coforall i in 0..numLocales-1 with (ref returnval) {
                                if (xlocal(x,vertexBeginG[i],vertexEndG[i]) ||
                                    xlocal(x,vertexBeginRG[i],vertexEndRG[i])) {
                                    var mystart=i*CMaxSize;
                                    //coforall j in localArrayG[mystart..mystart+LPG[i]-1] with (ref returnval){
                                    for j in localArrayG[mystart..mystart+LPG[i]-1] {
                                         if j==x {
                                            returnval=true;
                                            break;
                                         }
                                    }
                                }
                            }
                            return returnval;
                       }

                       //var UnVisitedSet= new set(int,parSafe = true);//use set to keep the unvisited vertices
                       //forall i in BoundBeginG[here.id]..BoundEndG[here.id]  with (ref UnVisitedSet) {
                       //       if depth[i]==-1 {
                       //          UnVisitedSet.add(i);
                       //       }
                       //}
                       coforall i in BoundBeginG[here.id]..BoundEndG[here.id]
                                                   with (ref LocalSet, ref RemoteSet)  {
                       //coforall i in UnVisitedSet with (ref LocalSet, ref RemoteSet)  {
                          if (depth[i]==-1) {
                              if xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) {
                                  var    numNF=nf[i];
                                  var    edgeId=sf[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=df[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if FrontierHas(j) {
                                               depth[i]=cur_level+1;
                                               if (xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    LocalSet.add(i);
                                               } 
                                               if (xremote(i,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(i,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    RemoteSet.add(i);
                                               }
                                         }
                                  }
                              } 
                              if xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])  {
                                  var    numNF=nfR[i];
                                  var    edgeId=sfR[i];
                                  var nextStart=max(edgeId,edgeBeginG[here.id]);
                                  var nextEnd=min(edgeEndG[here.id],edgeId+numNF-1);
                                  ref NF=dfR[nextStart..nextEnd];
                                  coforall j in NF with (ref LocalSet, ref RemoteSet) {
                                         if FrontierHas(j) {
                                               depth[i]=cur_level+1;
                                               if (xlocal(i,vertexBeginG[here.id],vertexEndG[here.id]) ||
                                                   xlocal(i,vertexBeginRG[here.id],vertexEndRG[here.id])) {
                                                    LocalSet.add(i);
                                               } 
                                               if (xremote(i,HvertexBeginG[here.id],TvertexEndG[here.id]) ||
                                                   xremote(i,HvertexBeginRG[here.id],TvertexEndRG[here.id])) {
                                                    RemoteSet.add(i);
                                               }
                                         }
                                  }
                              }
                          } //end if (depth[i]==-1)
                       }//end coforall
                   }// end bottom up
                       
                   if (RemoteSet.size>0) {//there is vertex to be sent
                                  remoteNum[here.id]+=RemoteSet.size;
                                  coforall localeNum in 0..numLocales-1  { 
                                       if localeNum != here.id{
                                         var ind=0:int;
                                         var agg= newDstAggregator(int); 
                                         for k in RemoteSet {
                                                if (xlocal(k,vertexBeginG[localeNum],vertexEndG[localeNum])||
                                                    xlocal(k,vertexBeginRG[localeNum],vertexEndRG[localeNum])){
                                                     agg.copy(recvArrayG[localeNum*numLocales*CMaxSize+
                                                                         here.id*CMaxSize+ind] ,k);
                                                     ind+=1;
                                                     
                                                }
                                         }
                                         agg.flush();
                                         RPG[localeNum*numLocales+here.id]=ind;
                                         ind=0;
                                       }
                                  }
                   }//end if

                   localNum[here.id]+=LPG[here.id];
                   LPG[here.id]=0;
                   if LocalSet.size>0 {
                       LPG[here.id]=LocalSet.size;
                       localNum[here.id]+=LocalSet.size;
                       var mystart=here.id*CMaxSize;
                       forall (a,b)  in zip (localArrayG[mystart..mystart+LocalSet.size-1],LocalSet.toArray()) {
                              a=b;
                       }
                   }
                   LocalSet.clear();
                   RemoteSet.clear();
                   //LPNG[here.id]=0;
                  }//end on loc
              }//end coforall loc
              coforall loc in Locales {
                  on loc {
                   var mystart=here.id*CMaxSize;
                   for i in 0..numLocales-1 {
                     if i != here.id {
                       if (RPG[here.id*numLocales+i]>0) {
                           localArrayG[mystart+LPG[here.id]..mystart+LPG[here.id]+RPG[numLocales*here.id+i]-1]=
                           recvArrayG[CMaxSize*numLocales*here.id+i*CMaxSize..
                                      CMaxSize*numLocales*here.id+i*CMaxSize+RPG[numLocales*here.id+i]-1];
                           LPG[here.id]=LPG[here.id]+RPG[numLocales*here.id+i];
                       }
                     }
                         
                   }
                  }//end on loc
              }//end coforall loc
              numCurF=0;
              for iL in 0..(numLocales-1)  {
                   if LPG[iL] >0 {
                       numCurF+=LPG[iL];
                       //break;
                   }
              }
              RPG=0;
              cur_level+=1;
          }//end while  
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$Search Radius = ", cur_level+1,"$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$number of top-down = ", topdown, " number of bottom-up=",bottomup, "$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          var TotalLocal=0:int;
          var TotalRemote=0:int;
          for i in 0..numLocales-1 {
            TotalLocal+=localNum[i];
            TotalRemote+=remoteNum[i];
          }
          writeln("Local Ratio=", (TotalLocal):real/(TotalLocal+TotalRemote):real,"Total Local Access=",TotalLocal," , Total Remote Access=",TotalRemote);
          return "success";
      }//end of co_d1_bfs_kernel_u

      proc return_depth(): string throws{
          var depthName = st.nextName();
          var depthEntry = new shared SymEntry(depth);
          st.addEntry(depthName, depthEntry);
          //try! st.addEntry(vertexName, vertexEntry);

          var depMsg =  'created ' + st.attrib(depthName);
          //var lrepMsg =  'created ' + st.attrib(levelName) + '+created ' + st.attrib(vertexName) ;
          return depMsg;

      }


      if (Directed!=0) {
          if (Weighted!=0) {
              var ratios:string;
              //var pn = Reflection.getRoutineName();
               (srcN, dstN, startN, neighbourN,vweightN,eweightN, rootN,ratios)=
                   restpart.splitMsgToTuple(8);
              root=rootN:int;
              var GivenRatio=ratios:real;
              if (RCMFlag>0) {
                  root=0;
              }
              depth[root]=0;
              var ag = new owned SegGraphDW(Nv,Ne,Directed,Weighted,srcN,dstN,
                                 startN,neighbourN,vweightN,eweightN, st);
              fo_bag_bfs_kernel(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,1,GivenRatio);
              repMsg=return_depth();

          } else {
              var ratios:string;

              (srcN, dstN, startN, neighbourN,rootN,ratios )=restpart.splitMsgToTuple(6);
              var ag = new owned SegGraphD(Nv,Ne,Directed,Weighted,srcN,dstN,
                      startN,neighbourN,st);
              root=rootN:int;
              var GivenRatio=ratios:real;
              if (RCMFlag>0) {
                  root=0;
              }
              depth[root]=0;
              fo_bag_bfs_kernel(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,1,GivenRatio);
              repMsg=return_depth();
          }
      }
      else {
          if (Weighted!=0) {
              var ratios:string;
              (srcN, dstN, startN, neighbourN,srcRN, dstRN, startRN, neighbourRN,vweightN,eweightN, rootN, ratios)=
                   restpart.splitMsgToTuple(12);
              var ag = new owned SegGraphUDW(Nv,Ne,Directed,Weighted,
                      srcN,dstN, startN,neighbourN,
                      srcRN,dstRN, startRN,neighbourRN,
                      vweightN,eweightN, st);
              root=rootN:int;
              if (RCMFlag>0) {
                  root=0;
              }
              depth=-1;
              depth[root]=0;
              var Flag=0:int;
              var GivenRatio=ratios:real;
              if (GivenRatio <0  ) {//do default call
                  GivenRatio=-1.0* GivenRatio;
                  //co_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                  //         ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,GivenRatio);
                  fo_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,1,GivenRatio);
                  repMsg=return_depth();
 
              } else {// do batch test
                  depth=-1;
                  depth[root]=0;
                  timer.stop();
                  timer.clear();
                  timer.start();
                  co_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co D Hybrid version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  Flag=1;
                  timer.clear();
                  timer.start();
                  co_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,2.0);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co D TopDown version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Bag L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  co_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Bag G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Set L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  co_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Set G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Domain L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  co_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Domain G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  fo_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for D Hybrid version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  fo_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,2.0);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for D TopDown version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  fo_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Bag L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  fo_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Bag G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  fo_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Set L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  fo_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Set G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  fo_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Domain L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  fo_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Domain G version $$$$$$$$$$$$$$$$$$");

                  repMsg=return_depth();
              }//end of batch test

          } else {
              var ratios:string;
              (srcN, dstN, startN, neighbourN,srcRN, dstRN, startRN, neighbourRN, rootN,ratios )=
                   restpart.splitMsgToTuple(10);
              var ag = new owned SegGraphUD(Nv,Ne,Directed,Weighted,
                      srcN,dstN, startN,neighbourN,
                      srcRN,dstRN, startRN,neighbourRN,
                      st);

              root=rootN:int;
              if (RCMFlag>0) {
                  root=0;
              }
              depth=-1;
              depth[root]=0;
              var Flag=0:int;
              var GivenRatio=ratios:real;
              if (GivenRatio <0 ) {//do default call
                  GivenRatio=-1.0*GivenRatio;
                  //co_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                  //         ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,GivenRatio);
                  fo_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,1,GivenRatio);
                  repMsg=return_depth();
 
              } else {// do batch test
                  timer.stop();
                  timer.clear();
                  timer.start();
                  co_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co D Hybrid version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,2.0);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co D TopDown version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Bag L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  co_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Bag G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Set L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  co_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Set G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  co_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Domain L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  co_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Co Domain G version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  fo_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for D Hybrid version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  fo_d1_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,2.0);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for D TopDown version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  fo_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Bag L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.start();
                  Flag=0;
                  fo_bag_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Bag G version $$$$$$$$$$$$$$$$$$");

 
                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  fo_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Set L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  fo_set_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Set G version $$$$$$$$$$$$$$$$$$");


                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=1;
                  fo_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Domain L version $$$$$$$$$$$$$$$$$$");

                  depth=-1;
                  depth[root]=0;
                  timer.clear();
                  timer.start();
                  Flag=0;
                  fo_domain_bfs_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a,Flag,GivenRatio);
                  timer.stop();
                  writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), " for Domain G version $$$$$$$$$$$$$$$$$$");



                  repMsg=return_depth();
              //repMsg=return_depth();
              }
          }
      }
      timer.stop();
      writeln("$$$$$$$$$$$$$$$$$ graph BFS takes ",timer.elapsed(), "$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);

  }

  proc segTriEdgeMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var repMsg: string;
      var (kTrussN,n_verticesN, n_edgesN, directedN, weightedN, restpart )
          = payload.splitMsgToTuple(6);
      var kValue=kTrussN:int;
      var Nv=n_verticesN:int;
      var Ne=n_edgesN:int;
      var Directed=directedN:int;
      var Weighted=weightedN:int;
      var countName:string;
      
      var StartEdgeAry=-1: [0..numLocales-1] int;
      var EndEdgeAry=-1: [0..numLocales-1] int;
      var RemoteAccessTimes=0: [0..numLocales-1] int;
      var LocalAccessTimes=0: [0..numLocales-1] int;

      //var timer=Timer;
      repMsg = "Success Number 2";
      var srcN, dstN, startN, neighbourN,vweightN,eweightN, rootN :string;
      var srcRN, dstRN, startRN, neighbourRN:string;
      //timer.start();
      var EdgeCnt=0: [0..Ne] int;
      //writeln(EdgeCnt);
      var EdgeFlags = 0:[0..Ne] int;
      var repCount=0:int;
      var EdgeCount = 0:[0..Ne] int;
      

      proc tri_edge_kernel(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          //coforall loc in Locales 
          //iterate through the edgelist
          //Pass each edge to a locale
          //Within each locale iterate on the left or the right. 
          //
          var Iterations=0:int;
          var k = 4:int;
          ref srcRef = src;
          ref dstRef = dst;
          var forwardVertice:int;
          var reverseVertice:int;
          var ConFlag=0:int;
          ConFlag = 1;
          var EdgeFlag = 0:[0..Ne-1] int;
          
          while (ConFlag == 1) {
          Iterations +=1;
          ConFlag = 0;
          for i in 0..Ne-1 { //begin edge iteration
              forwardVertice=src[i];
              reverseVertice=dst[i];
              var uadj = new set(int, parSafe = true);
              var vadj = new set(int, parSafe = true);
              var tricount:int;
              tricount=0;
              //writeln(forwardVertice, ",", reverseVertice); 
          //Get current edge: Big candidate for parallelization
              if (EdgeFlag[i] != -1) {
              for u in 0..Ne-1 { //begin edgelist iteration
                  if (EdgeFlag[u] != -1) {
                  if (srcRef[u] == forwardVertice) {
                      uadj.add(dstRef[u]); 
                  
                      }
                  if (srcRef[u] == reverseVertice) {
                      vadj.add(dstRef[u]);
                      } 
                      }
                  }//end edgelist iteration
              for v in 0..Ne-1 {//begin reverse edgelist iteration
                  if (EdgeFlag[v] != -1) {
                  if (dstRef[v] == forwardVertice) {
                      uadj.add(srcRef[v]);
                      }
                  if (dstRef[v] == reverseVertice) {
                      vadj.add(srcRef[v]);
                      }
                      }
                  }
              for u in uadj {
                  if vadj.contains(u) {
                      tricount += 1;
                      }
                  }
                  EdgeCnt[i] = tricount;
                  }
              }//end edge iteration
              
              
          //writeln(EdgeCnt);
          
          for i in 0..Ne-1 {
              if ((EdgeCnt[i] < k-2) && (EdgeCnt[i] > 0) && (EdgeFlag[i]==0)) {
                  EdgeCnt[i] -= 1;
                  ConFlag = 1;
                  EdgeFlag[i] = -1;
                  
              }
          }
          }
          //writeln(EdgeCnt);
          writeln("Number of Iterations: ", Iterations);
       
          var tmpi=0:int;
          for i in 0..Ne-1 {
              if EdgeFlag[i]==-1 {
                  //writeln("remove the ",tmpi, " edge ",i);
                  tmpi+=1;
              }
          }
          writeln("totally remove ",tmpi, " edge ");
          return "Yay";   
          }
          
      proc kTrussParallel(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
                        
                        var k:int;
                        k = 2;
                        var EdgeFlags: [1..Ne] [1..2] int;
                        //var EdgeDegree = 0:[0..Ne] int;
                        coforall loc in Locales {
                            on loc {
                                writeln("Here I am");
                                
                                var uadj = new set(int, parSafe = true);
                                var vadj = new set(int, parSafe = true);
                                var tricountPar:int; 
                                var ld = src.localSubdomain();
                                ref srcRef = src;
                                ref dstRef = dst;
                                var startEdge = ld.low;
                                var endEdge = ld.high;
                                writeln(startEdge, endEdge);
                                var forwardVertice:int;
                                var reverseVertice:int;
                                var EdgeCount=0:[0..Ne] int;
                                ref EdgeFlaged = EdgeFlags;
                                var EdgeDeg=0:int;
                                
                                
                                
                                for j in 0..50 {
                                    writeln("Beginning first Iteration");
                                    EdgeCount = 0:[0..Ne] int;
                                    
                                    for i in startEdge..endEdge {
                                        forwardVertice = srcRef[i];
                                        reverseVertice = dstRef[i];
                                        uadj.clear();
                                        vadj.clear();
                                        tricountPar=0;
                                        EdgeDeg = 0;
                                        
                                        if (EdgeFlaged[i,0] != -1) {
                                            forall u in 0..Ne-1 {
                                                if (EdgeFlaged[u] == 0) {
                                                    if (srcRef[u] == forwardVertice) {
                                                        uadj.add(dstRef[u]);
                                                        EdgeDeg +=1;
                                                    }
                                                
                                                if (srcRef[u] == reverseVertice) {
			                             vadj.add(dstRef[u]);
			                             EdgeDeg[i] +=1;
			                         }
			                         } 
                                            }    //end edgelist iteration
                                            forall v in 0..Ne-1 {//begin reverse edgelist iteration
                                                if (EdgeFlaged[v,0] == 0) { 
                                                    if (dstRef[v] == forwardVertice) {
                                                        uadj.add(srcRef[v]);
                                                        EdgeDeg +=1;
                                                    }
                                                    if (dstRef[v] == reverseVertice) {
                                                        vadj.add(srcRef[v]);
                                                        EdgeDeg +=1;
                                                    }
                                                }
                                            }
                                            forall u in uadj {
                                                if vadj.contains(u) {
                                                 tricountPar +=1;
                                            }
                                            
                                        }
                                        EdgeFlaged[i,0]=EdgeDeg;
                                        EdgeCount[i] = tricountPar;
                                    }


                                    }
                                    writeln("Changing Edges");
                                    for e in startEdge..endEdge {
                                        if (EdgeCount[e] < k) {
                                            EdgeFlaged[e] = -1;

                                            }
                                        }
                                          

                                
                        
                        if (j==0) {
                        writeln("Real counts ", EdgeCount);
                        }
                        if (j==49) {
                        writeln("Iterative Edge Count");
                        forall g in 0..Ne-1 {
                            if (EdgeCount[g] > 0) {
                                writeln(src[g], "," , dst[g], " Tri Value ", EdgeCount[g]);
                            }
                        }
                        } 
                        }
                    }
                    }

                    return "Yay";
                    }
                    
                    
      // this can be a general procedure so we put it outside
      proc xlocal(x :int, low:int, high:int):bool{
                if (low<=x && x<=high) {
                      return true;
                } else {
                      return false;
                }
      }

      proc binSearchE(ary:[?D] int,l:int,h:int,key:int):int {
                       if ( l<D.low || h>D.high) {
                           return -1;
                       }
                       if ( (l>h) || ((l==h) && ( ary[l]!=key)))  {
                            return -1;
                       }
                       if (ary[l]==key){
                            return l;
                       }
                       if (ary[h]==key){
                            return h;
                       }
                       var m= (l+h)/2:int;
                       if (ary[m]==key ){
                            return m;
                       } else {
                            if (ary[m]<key) {
                              return binSearchE(ary,m+1,h,key);
                            }
                            else {
                                    return binSearchE(ary,l,m-1,key);
                            }
                       }
                       return -1;
      }// end of proc


      proc kTrussNaive(k:int,nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          var EdgeDeleted=makeDistArray(Ne,bool); //we need a global instead of local array
          var N1=0:int;
          var N2=0:int;
          var ConFlag=true:bool;
          EdgeDeleted=false;
          var RemovedEdge=0: int;
          var TriCount=makeDistArray(Ne,bool): int;
          TriCount=0;
          var timer:Timer;

          proc FindDuplicatedEdges( cur: int):int {

               if ((cur<D3.low) || (cur >D3.high)) {
                    return -1;
               }
               var u=src[cur]:int;
               var v=dst[cur]:int;
               var DupE=binSearchE(dst,start_i[u],cur-1,v);
               if (DupE!=-1) {
                    EdgeDeleted[cur]=true;
                    writeln("In function  Find duplicated edges ",cur,"=<",src[cur],",",dst[cur],"> and ", DupE,"=<", src[DupE],",",dst[DupE],">");
               } else {
                   if (u>v) {
                      if (nei[v]<=0) {
                         DupE=-1;
                      } else {
                         DupE=binSearchE(dst,start_i[v],start_i[v]+nei[v]-1,u);
                      }
                      if (DupE!=-1) {
                           EdgeDeleted[cur]=true;
                           writeln("In function  Find duplicated edges ",cur,"=<",src[cur],",",dst[cur],"> and ", DupE,"=<", src[DupE],",",dst[DupE],">");
                      }
                   }
               }
               return DupE;
          }

          // given vertces u and v, return the edge ID e=<u,v> or e=<v,u>
          proc findEdge(u:int,v:int):int {
              //given the destinontion arry ary, the edge range [l,h], return the edge ID e where ary[e]=key
              if ((u==v) || (u<D1.low) || (v<D1.low) || (u>D1.high) || (v>D1.high) ) {
                    return -1;
                    // we do not accept self-loop
              }
              var beginE=start_i[u];
              var eid:int;
              if ( (beginE>=0) && (v>=dst[beginE]) && (v<=dst[beginE+nei[u]-1]) )  {
                       eid=binSearchE(dst,beginE,beginE+nei[u]-1,v);
                       // search <u,v> in undirect edges 
              } else {
                eid=-1;
              }
              if (eid==-1) {// if b
                 beginE=start_i[v];
                 if ( (beginE>=0) && (u>=dst[beginE]) && (u<=dst[beginE+nei[v]-1]) )  {
                       eid=binSearchE(dst,beginE,beginE+nei[v]-1,u);
                       // search <v,u> in undirect edges 
                 } else {
                    eid=-1;
                 }
              }// end of if b

              /*
                 if (eid==-1) {// if a
                    beginE=start_iR[u];
                    if ( (beginE>=0) && (v>=dstR[beginE]) && (v<=dstR[beginE+neiR[u]-1]) )  {
                       var e=binSearchE(dstR,beginE,beginE+neiR[u]-1,v);
                       // search <u,v> in reverse undirect edges 
                       if (e!=-1) {
                           var v1=srcR[e];
                           var v2=dstR[e];
                           //here we change the edge ID found in reverse array srcR and dstR into the ID of src and dst
                           eid=binSearchE(dst,start_i[v2],start_i[v2]+nei[v2]-1,v1);
                           // search <v,u> in reverse undirect edges 
                       }   else {
                           eid=-1;
                       }
                       if (eid==-1) {
                         beginE=start_iR[v];
                         if ( (beginE>=0) && (u>=dstR[beginE]) && (u<=dstR[beginE+neiR[v]-1]) )  {
                            var e=binSearchE(dstR,beginE,beginE+neiR[v]-1,u);
                            if (e!=-1) {
                               var v1=srcR[e];
                               var v2=dstR[e];
                               //here we change the edge ID found in reverse array srcR and dstR into the ID of src and dst
                               eid=binSearchE(dst,start_i[v2],start_i[v2]+nei[v2]-1,v1);
                             } else {
                                 eid=-1;
                             }
                         } else {
                             eid=-1;
                         }
                       } 
                    } else {
                       eid=-1;
                    } 
                 }// end of if a
              */
              return eid;
          }// end of  proc findEdge(u:int,v:int)
          //here we begin the first naive version
          timer.start();
          coforall loc in Locales {
              on loc {
                    var ld = src.localSubdomain();
                    var startEdge = ld.low;
                    var endEdge = ld.high;
                    forall i in startEdge..endEdge {
                        var v1=src[i];
                        var v2=dst[i];
                        if (  (nei[v1]+neiR[v1])<k-1  || 
                             ((nei[v2]+neiR[v2])<k-1) || (v1==v2)) {
                            //we will delete all the edges connected with a vertex only has very small degree 
                            //(less than k-1)
                              EdgeDeleted[i]=true;
                              //writeln("For k=",k," We have removed the edge ",i, "=<",v1,",",v2,">");
                              //writeln("Degree of ",v1,"=",nei[v1]+neiR[v1]," Degree of ",v2, "=",nei[v2]+neiR[v2]);
                              // we can safely delete the edge <u,v> if the degree of u or v is less than k-1
                              // we also remove the self-loop like <v,v>
                              if (v1==v2) {
                                   //writeln("My locale=",here.id," Find self-loop ",i,"=<",src[i],",",dst[i],">");
                              }
                        }
                        if (EdgeDeleted[i]==false) {
                             var DupE= FindDuplicatedEdges(i);
                             if (DupE!=-1) {
                                  //writeln("My locale=",here.id, " Find duplicated edges ",i,"=<",src[i],",",dst[i],"> and ", DupE,"=<", src[DupE],",",dst[DupE],">");
                                  if (!EdgeDeleted[i]) {
                                          writeln("My locale=",here.id, " before assignment edge ",i," has not been set as true");
                                  }
                                  EdgeDeleted[i]=true;
                             }
                        }
                    }
              }        
          }// end of coforall loc        


          //we will try to remove all the unnecessary edges in the graph
          while (ConFlag) {
              //ConFlag=false;
              // first we calculate the number of triangles
              coforall loc in Locales with (ref SetCurF ) {
                  on loc {
                     var ld = src.localSubdomain();
                     var startEdge = ld.low;
                     var endEdge = ld.high;
                     //writeln("Begin Edge=",startEdge, " End Edge=",endEdge);
                     // each locale only handles the edges owned by itself
                     forall i in startEdge..endEdge with(ref SetCurF){
                         TriCount[i]=0;
                         var uadj = new set(int, parSafe = true);
                         var vadj = new set(int, parSafe = true);
                         var u = src[i];
                         var v = dst[i];
                         //writeln("1 My Locale=",here.id," Current Edge=",i, "=<",u,",",v,">");
                         var beginTmp=start_i[u];
                         var endTmp=beginTmp+nei[u]-1;
                         if ((EdgeDeleted[i]==false) && (u!=v) ){
                            if ( (nei[u]>0)  ){
                               forall x in dst[beginTmp..endTmp] with (ref uadj) {
                                   var  e=findEdge(u,x);//here we find the edge ID to check if it has been removed
                                   if (e==-1){
                                      //writeln("vertex ",x," and ",u," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=v)) {
                                             uadj.add(x);
                                   }
                               }
                            }
                            beginTmp=start_iR[u];
                            endTmp=beginTmp+neiR[u]-1;
                            if ((neiR[u]>0) ){
                               forall x in dstR[beginTmp..endTmp] with (ref uadj) {
                                   var e=findEdge(x,u);
                                   if (e==-1){
                                      //writeln("vertex ",x," and ",u," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=v)) {
                                             uadj.add(x);
                                   }
                               }
                            }
                            
                            //writeln("2 ", "My Locale=", here.id, " The adjacent vertices of ",u,"->",v," =",uadj);
                            if  (! uadj.isEmpty() ){
                               var Count=0:int;
                               forall s in uadj with ( + reduce Count) {
                                   var e=findEdge(s,v);
                                   if ( (e!=-1) && (EdgeDeleted[e]==false) && (e!=i) ) {
                                      Count +=1;
                                      //writeln("3 My locale=",here.id, " The ", Count, " Triangle <",u,",",v,",",s,"> is added");
                                   }
                               }
                               TriCount[i] = Count;
                               //writeln("4 My Locale=", here.id, " The number of triangles of edge ",i,"=<",u,",",v," > is ", Count);
                               // here we get the number of triangles of edge ID i
                            }// end of if (EdgeDeleterd[i]==false ) 
                            /*
                            beginTmp=start_i[v];
                            endTmp=beginTmp+nei[v]-1;
                            if ((nei[v]>0)){
                               forall x in dst[beginTmp..endTmp] with (ref vadj) {
                                   var e=findEdge(v,x);
                                   if (e==-1){
                                      //writeln("vertex ",x," and ",v," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=u)) {
                                             vadj.add(x);
                                   }
                               }
                            }
                            beginTmp=start_iR[v];
                            endTmp=beginTmp+neiR[v]-1;
                            if ((neiR[v]>0)){
                               forall x in dstR[beginTmp..endTmp] with (ref vadj) {
                                   var e=findEdge(x,v);
                                   if (e==-1){
                                      writeln("vertex ",x," and ",v," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=u)) {
                                             vadj.add(x);
                                   }
                               }
                            }
                            //writeln("The adjacent vertices of ",v,"->",u," =",vadj);
                            //if ((EdgeDeleted[i]==false) ){
                            if ( (! uadj.isEmpty())&&(!vadj.isEmpty())){
                               var Count=0:int;
                               forall s in uadj with ( + reduce Count) {
                                   if vadj.contains(s) {
                                      Count +=1;
                                      //writeln("The ", Count, " Triangle <",u,",",v,",",s,"> is added");
                                   }
                               }
                               TriCount[i] = Count;
                               //writeln("The number of triangles of edge ",i,"=<",u,",",v," > is ", Count);
                               // here we get the number of triangles of edge ID i
                            }// end of if (EdgeDeleterd[i]==false ) 
                            */
                        }//end of if
                     }// end of forall. We get the number of triangles for each edge
                  }// end of  on loc 
              } // end of coforall loc in Locales 
              coforall loc in Locales with (ref SetCurF ) {
                  on loc {
                     var ld = src.localSubdomain();
                     var startEdge = ld.low;
                     var endEdge = ld.high;
                     //writeln("9 My locale=",here.id, " Begin Edge=",startEdge, " End Edge=",endEdge);
                     // each locale only handles the edges owned by itself
                     forall i in startEdge..endEdge with(ref SetCurF){
                               if ((EdgeDeleted[i]==false) && (TriCount[i] < k-2)) {
                                     EdgeDeleted[i] = true;
                                     SetCurF.add(i);
                                     //writeln("10 My Locale=",here.id," removed edge ",i,"=<",src[i],",",dst[i]," > Triangles=",TriCount[i], " in iteration=",N1);
                                     //KeepCheck[here.id]=true;
                               }
                     }
                  }// end of  on loc 
              } // end of coforall loc in Locales 
              N1+=1;
              if ( SetCurF.getSize()<=0){
                      ConFlag=false;
              } else {
                      //writeln("11 My Locale=", here.id, " Iteration ", N1," ", SetCurF.getSize(), " Edges have been removed");
              }
              SetCurF.clear();
              //for i in KeepCheck[0..numLocales-1] {
              //     if i {
              //        ConFlag=true;
              //     }
              //}
          }// end while (KeepCheck) 
          timer.stop();
          writeln("Before Optimization Total time=",timer.elapsed() );
          writeln("Before Optimization Total number of iterations=",N1);
          var tmpi=0:int;
          for i in 0..Ne-1 {
              if EdgeDeleted[i] {
                  //writeln("remove the ",tmpi, " edge ",i);
                  tmpi+=1;
              }
          }
          writeln("Before optimization totally removed  ",tmpi, " edges ");

          return "completed";
      } // end of proc kTrussNavie(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
        
        
        
      proc kTrussOpt(k:int,nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var SetCurF=  new DistBag(int,Locales);//use bag to keep the current frontier
          var SetNextF=  new DistBag(int,Locales); //use bag to keep the next frontier
          var EdgeDeleted=makeDistArray(Ne,bool); //we need a global instead of local array
          //var RemovedEdge=makeDistArray(numLocales,int);// we accumulate the edges according to different locales
          //var KeepCheck=makeDistArray(numLocales,bool);// we accumulate the edges according to different locales
          var N1=0:int;
          var N2=0:int;
          var ConFlag=true:bool;
          //KeepCheck=true;
          EdgeDeleted=false;
          var RemovedEdge=0: int;
          var TriCount=makeDistArray(Ne,bool): int;
          TriCount=0;
          var timer:Timer;



          proc FindDuplicatedEdges( cur: int):int {

               if ((cur<D3.low) || (cur >D3.high)) {
                    return -1;
               }
               var u=src[cur]:int;
               var v=dst[cur]:int;
               var DupE=binSearchE(dst,start_i[u],cur-1,v);
               if (DupE!=-1) {
                    EdgeDeleted[cur]=true;
                    writeln("In function  Find duplicated edges ",cur,"=<",src[cur],",",dst[cur],"> and ", DupE,"=<", src[DupE],",",dst[DupE],">");
               } else {
                   if (u>v) {
                      if (nei[v]<=0) {
                         DupE=-1;
                      } else {
                         DupE=binSearchE(dst,start_i[v],start_i[v]+nei[v]-1,u);
                      }
                      if (DupE!=-1) {
                           EdgeDeleted[cur]=true;
                           writeln("In function  Find duplicated edges ",cur,"=<",src[cur],",",dst[cur],"> and ", DupE,"=<", src[DupE],",",dst[DupE],">");
                      }
                   }
               }
               return DupE;
          }

          // given vertces u and v, return the edge ID e=<u,v> or e=<v,u>
          proc findEdge(u:int,v:int):int {
              //given the destinontion arry ary, the edge range [l,h], return the edge ID e where ary[e]=key
              if ((u==v) || (u<D1.low) || (v<D1.low) || (u>D1.high) || (v>D1.high) ) {
                    return -1;
                    // we do not accept self-loop
              }
              var beginE=start_i[u];
              var eid:int;
              if ( (beginE>=0) && (v>=dst[beginE]) && (v<=dst[beginE+nei[u]-1]) )  {
                       eid=binSearchE(dst,beginE,beginE+nei[u]-1,v);
                       // search <u,v> in undirect edges 
              } else {
                eid=-1;
              }
              if (eid==-1) {// if b
                 beginE=start_i[v];
                 if ( (beginE>=0) && (u>=dst[beginE]) && (u<=dst[beginE+nei[v]-1]) )  {
                       eid=binSearchE(dst,beginE,beginE+nei[v]-1,u);
                       // search <v,u> in undirect edges 
                 } else {
                    eid=-1;
                 }
              }// end of if b

              /*
                 if (eid==-1) {// if a
                    beginE=start_iR[u];
                    if ( (beginE>=0) && (v>=dstR[beginE]) && (v<=dstR[beginE+neiR[u]-1]) )  {
                       var e=binSearchE(dstR,beginE,beginE+neiR[u]-1,v);
                       // search <u,v> in reverse undirect edges 
                       if (e!=-1) {
                           var v1=srcR[e];
                           var v2=dstR[e];
                           //here we change the edge ID found in reverse array srcR and dstR into the ID of src and dst
                           eid=binSearchE(dst,start_i[v2],start_i[v2]+nei[v2]-1,v1);
                           // search <v,u> in reverse undirect edges 
                       }   else {
                           eid=-1;
                       }
                       if (eid==-1) {
                         beginE=start_iR[v];
                         if ( (beginE>=0) && (u>=dstR[beginE]) && (u<=dstR[beginE+neiR[v]-1]) )  {
                            var e=binSearchE(dstR,beginE,beginE+neiR[v]-1,u);
                            if (e!=-1) {
                               var v1=srcR[e];
                               var v2=dstR[e];
                               //here we change the edge ID found in reverse array srcR and dstR into the ID of src and dst
                               eid=binSearchE(dst,start_i[v2],start_i[v2]+nei[v2]-1,v1);
                             } else {
                                 eid=-1;
                             }
                         } else {
                             eid=-1;
                         }
                       } 
                    } else {
                       eid=-1;
                    } 
                 }// end of if a
              */
              return eid;
          }// end of  proc findEdge(u:int,v:int)

          EdgeDeleted=false;
          timer.start();

          coforall loc in Locales {
              on loc {
                    var ld = src.localSubdomain();
                    var startEdge = ld.low;
                    var endEdge = ld.high;
                    forall i in startEdge..endEdge {
                        var v1=src[i];
                        var v2=dst[i];
                        if (  (nei[v1]+neiR[v1])<k-1  || 
                             ((nei[v2]+neiR[v2])<k-1) || (v1==v2)) {
                            //we will delete all the edges connected with a vertex only has very small degree 
                            //(less than k-1)
                              EdgeDeleted[i]=true;
                              //writeln("For k=",k," We have removed the edge ",i, "=<",v1,",",v2,">");
                              //writeln("Degree of ",v1,"=",nei[v1]+neiR[v1]," Degree of ",v2, "=",nei[v2]+neiR[v2]);
                              // we can safely delete the edge <u,v> if the degree of u or v is less than k-1
                              // we also remove the self-loop like <v,v>
                              if (v1==v2) {
                                   //writeln("My locale=",here.id," Find self-loop ",i,"=<",src[i],",",dst[i],">");
                              }
                        }
                        if (EdgeDeleted[i]==false) {
                             var DupE= FindDuplicatedEdges(i);
                             if (DupE!=-1) {
                                  //writeln("My locale=",here.id, " Find duplicated edges ",i,"=<",src[i],",",dst[i],"> and ", DupE,"=<", src[DupE],",",dst[DupE],">");
                                  if (!EdgeDeleted[i]) {
                                          writeln("My locale=",here.id, " before assignment edge ",i," has not been set as true");
                                  }
                                  EdgeDeleted[i]=true;
                             }
                        }
                    }
              }        
          }// end of coforall loc        

          //we will try to remove all the unnecessary edges in the graph
          while (ConFlag) {
              //ConFlag=false;
              // first we calculate the number of triangles
              coforall loc in Locales with (ref SetCurF ) {
                  on loc {
                     var ld = src.localSubdomain();
                     var startEdge = ld.low;
                     var endEdge = ld.high;
                     //writeln("Begin Edge=",startEdge, " End Edge=",endEdge);
                     // each locale only handles the edges owned by itself
                     forall i in startEdge..endEdge with(ref SetCurF){
                         TriCount[i]=0;
                         var uadj = new set(int, parSafe = true);
                         var vadj = new set(int, parSafe = true);
                         var u = src[i];
                         var v = dst[i];
                         //writeln("1 My Locale=",here.id," Current Edge=",i, "=<",u,",",v,">");
                         var beginTmp=start_i[u];
                         var endTmp=beginTmp+nei[u]-1;
                         if ((EdgeDeleted[i]==false) && (u!=v) ){
                            if ( (nei[u]>0)  ){
                               forall x in dst[beginTmp..endTmp] with (ref uadj) {
                                   var  e=findEdge(u,x);//here we find the edge ID to check if it has been removed
                                   if (e==-1){
                                      //writeln("vertex ",x," and ",u," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=v)) {
                                             uadj.add(x);
                                   }
                               }
                            }
                            beginTmp=start_iR[u];
                            endTmp=beginTmp+neiR[u]-1;
                            if ((neiR[u]>0) ){
                               forall x in dstR[beginTmp..endTmp] with (ref uadj) {
                                   var e=findEdge(x,u);
                                   if (e==-1){
                                      //writeln("vertex ",x," and ",u," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=v)) {
                                             uadj.add(x);
                                   }
                               }
                            }
                            
                            //writeln("2 ", "My Locale=", here.id, " The adjacent vertices of ",u,"->",v," =",uadj);
                            if  (! uadj.isEmpty() ){
                               var Count=0:int;
                               forall s in uadj with ( + reduce Count) {
                                   var e=findEdge(s,v);
                                   if ( (e!=-1) && (EdgeDeleted[e]==false) && (e!=i) ) {
                                      Count +=1;
                                      //writeln("3 My locale=",here.id, " The ", Count, " Triangle <",u,",",v,",",s,"> is added");
                                   }
                               }
                               TriCount[i] = Count;
                               //writeln("4 My Locale=", here.id, " The number of triangles of edge ",i,"=<",u,",",v," > is ", Count);
                               // here we get the number of triangles of edge ID i
                            }// end of if (EdgeDeleterd[i]==false ) 
                            /*
                            beginTmp=start_i[v];
                            endTmp=beginTmp+nei[v]-1;
                            if ((nei[v]>0)){
                               forall x in dst[beginTmp..endTmp] with (ref vadj) {
                                   var e=findEdge(v,x);
                                   if (e==-1){
                                      //writeln("vertex ",x," and ",v," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=u)) {
                                             vadj.add(x);
                                   }
                               }
                            }
                            beginTmp=start_iR[v];
                            endTmp=beginTmp+neiR[v]-1;
                            if ((neiR[v]>0)){
                               forall x in dstR[beginTmp..endTmp] with (ref vadj) {
                                   var e=findEdge(x,v);
                                   if (e==-1){
                                      writeln("vertex ",x," and ",v," findEdge Error");
                                   }
                                   if ((EdgeDeleted[e] ==false) && (x !=u)) {
                                             vadj.add(x);
                                   }
                               }
                            }
                            //writeln("The adjacent vertices of ",v,"->",u," =",vadj);
                            //if ((EdgeDeleted[i]==false) ){
                            if ( (! uadj.isEmpty())&&(!vadj.isEmpty())){
                               var Count=0:int;
                               forall s in uadj with ( + reduce Count) {
                                   if vadj.contains(s) {
                                      Count +=1;
                                      //writeln("The ", Count, " Triangle <",u,",",v,",",s,"> is added");
                                   }
                               }
                               TriCount[i] = Count;
                               //writeln("The number of triangles of edge ",i,"=<",u,",",v," > is ", Count);
                               // here we get the number of triangles of edge ID i
                            }// end of if (EdgeDeleterd[i]==false ) 
                            */
                        }//end of if
                     }// end of forall. We get the number of triangles for each edge
                  }// end of  on loc 
              } // end of coforall loc in Locales 
              coforall loc in Locales with (ref SetCurF ) {
                  on loc {
                     var ld = src.localSubdomain();
                     var startEdge = ld.low;
                     var endEdge = ld.high;
                     //writeln("9 My locale=",here.id, " Begin Edge=",startEdge, " End Edge=",endEdge);
                     // each locale only handles the edges owned by itself
                     forall i in startEdge..endEdge with(ref SetCurF){
                               if ((EdgeDeleted[i]==false) && (TriCount[i] < k-2)) {
                                     EdgeDeleted[i] = true;
                                     SetCurF.add(i);
                                     //writeln("10 My Locale=",here.id," removed edge ",i,"=<",src[i],",",dst[i]," > Triangles=",TriCount[i], " in iteration=",N1);
                                     //KeepCheck[here.id]=true;
                               }
                     }
                  }// end of  on loc 
              } // end of coforall loc in Locales 



              //writeln("Current frontier =",SetCurF);
              //if (!SetCurF.isEmpty()) {
              if ( SetCurF.getSize()<=0){
                      ConFlag=false;
              }
              //while (!SetCurF.isEmpty()) {
              while (SetCurF.getSize()>0) {
                  coforall loc in Locales with ( ref SetCurF, ref SetNextF) {
                      on loc {
                           var ld = src.localSubdomain();
                           var startEdge = ld.low;
                           var endEdge = ld.high;
                           forall i in SetCurF with (ref SetNextF) {
                              if (xlocal(i,startEdge,endEdge)) {//each local only check the owned edges
                                  var    v1=src[i];
                                  var    v2=dst[i];
                                  var nextStart=start_i[v1];
                                  var nextEnd=start_i[v1]+nei[v1]-1;
                                  forall j in nextStart..nextEnd with (ref SetNextF){
                                         var v3=src[j];//v3==v1
                                         var v4=dst[j]; 
                                         var tmpe:int;
                                         if ( (EdgeDeleted[j]==false) && (v2!=v4 )) {
                                                   tmpe=findEdge(v2,v4);
                                                   if (tmpe!=-1) {// there is such third edge
                                                       if (EdgeDeleted[tmpe]==false) {// the edge has not been deleted
                                                          TriCount[j]-=1;//reduce the number of triangles
                                                          TriCount[tmpe]-=1;//reduce the number of triangles
                                                          if (TriCount[j]<k-2) {
                                                              EdgeDeleted[j]=true;
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",j,"=<",src[j],",",dst[j]," > Triangles=",TriCount[j]);
                                                              SetNextF.add(j);
                                                          }
                                                          if (TriCount[tmpe]<k-2) {
                                                              EdgeDeleted[tmpe]=true;
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",tmpe,"=<",src[tmpe],",",dst[tmpe]," > Triangles=",TriCount[tmpe] );
                                                              //writeln("Once Iteration, we removed edge ",j,"=<",src[j],",",dst[j]," >");
                                                              SetNextF.add(tmpe);
                                                          }
                                                       }
                                                   }
                                         }
                                  }// end of  forall j in nextStart..nextEnd 

                                  nextStart=start_i[v2];
                                  nextEnd=start_i[v2]+nei[v2]-1;
                                  if ((nextStart!=-1) && (nei[v2]>0)) {
                                     forall j in nextStart..nextEnd with (ref SetNextF){
                                         var v3=src[j];//v3==v2
                                         var v4=dst[j]; 
                                         var tmpe:int;
                                         if ( (EdgeDeleted[j]==false) && (v1!=v4) ) {
                                                   tmpe=findEdge(v1,v4);
                                                   if (tmpe!=-1) {// there is such third edge
                                                       if (EdgeDeleted[tmpe]==false) {// the edge has not been deleted
                                                          TriCount[j]-=1;//reduce the number of triangles
                                                          TriCount[tmpe]-=1;//reduce the number of triangles
                                                          if (TriCount[j]<k-2) {
                                                              EdgeDeleted[j]=true;
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",j,"=<",src[j],",",dst[j]," > Triangles=",TriCount[j]);
                                                              //writeln("Once Iteration, we removed edge ",j,"=<",src[j],",",dst[j]," >");
                                                              SetNextF.add(j);
                                                          }
                                                          if (TriCount[tmpe]<k-2) {
                                                              EdgeDeleted[tmpe]=true;
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",tmpe,"=<",src[tmpe],",",dst[tmpe]," > Triangles=",TriCount[tmpe] );
                                                              //writeln("Once Iteration, we removed edge ",j,"=<",src[j],",",dst[j]," >");
                                                              SetNextF.add(tmpe);
                                                          }
                                                       }
                                                   }
                                         }
                                     }// end of  forall j in nextStart..nextEnd 
                                  }// end of  if 


                                  nextStart=start_iR[v1];
                                  nextEnd=start_iR[v1]+neiR[v1]-1;
                                  if ((nextStart!=-1) && (neiR[v1]>0)) {
                                     forall j in nextStart..nextEnd with (ref SetNextF){
                                         var v3=srcR[j];//v1==v3
                                         var v4=dstR[j]; 
                                         var e1=findEdge(v3,v4);// we need the edge ID in src instead of srcR
                                         var tmpe:int;
                                         if ( (EdgeDeleted[e1]==false) && (v2!=v4)) {
                                                   // we first check if  the two different vertices can be the third edge
                                                   tmpe=findEdge(v2,v4);
                                                   if (tmpe!=-1) {
                                                       if (EdgeDeleted[tmpe]==false) {
                                                          TriCount[e1]-=1;
                                                          TriCount[tmpe]-=1;
                                                          if (TriCount[e1]<k-2) {
                                                              EdgeDeleted[e1]=true;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",j,"=<",src[j],",",dst[j]," > Triangles=",TriCount[j]);
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("Once Iteration, we removed edge ",e1,"=<",src[e1],",",dst[e1]," >");
                                                              SetNextF.add(e1);
                                                          }
                                                          if (TriCount[tmpe]<k-2) {
                                                              EdgeDeleted[tmpe]=true;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",tmpe,"=<",src[tmpe],",",dst[tmpe]," > Triangles=",TriCount[tmpe] );
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("Once Iteration, we removed edge ",j,"=<",src[j],",",dst[j]," >");
                                                              SetNextF.add(tmpe);
                                                          }
                                                       }
                                                   }
                                         }
                                     }// end of  forall j in nextStart..nextEnd 
                                  }// end of if

                                  nextStart=start_iR[v2];
                                  nextEnd=start_iR[v2]+neiR[v2]-1;
                                  if ((nextStart!=-1) && (neiR[v2]>0)) {
                                     forall j in nextStart..nextEnd with (ref SetNextF){
                                         var v3=srcR[j]; //v2==v3
                                         var v4=dstR[j]; 
                                         var e1=findEdge(v3,v4);// here we get the edge ID=<v3,v4>
                                         var tmpe:int;
                                         if ( EdgeDeleted[e1]==false ) {
                                                   // we first check if  the two different vertices can be the third edge
                                                   tmpe=findEdge(v1,v4);
                                                   if (tmpe!=-1) {
                                                       if (EdgeDeleted[tmpe]==false) {
                                                          TriCount[e1]-=1;
                                                          TriCount[tmpe]-=1;
                                                          if (TriCount[e1]<k-2) {
                                                              EdgeDeleted[e1]=true;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",j,"=<",src[j],",",dst[j]," > Triangles=",TriCount[j]);
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("Once Iteration, we removed edge ",e1,"=<",src[e1],",",dst[e1]," >");
                                                              SetNextF.add(e1);
                                                          }
                                                          if (TriCount[tmpe]<k-2) {
                                                              EdgeDeleted[tmpe]=true;
                                                              //writeln("My locale=", here.id, " After Iteration",N2," we removed edge ",tmpe,"=<",src[tmpe],",",dst[tmpe]," > Triangles=",TriCount[tmpe] );
                                                              //RemovedEdge[here.id]+=1;
                                                              //writeln("Once Iteration, we removed edge ",j,"=<",src[j],",",dst[j]," >");
                                                              SetNextF.add(tmpe);
                                                          }
                                                       }
                                                   }
                                         }
                                     }// end of  forall j in nextStart..nextEnd 
                                  }// end of  if
                              } // end if (xlocal(i,startEdge,endEdge) 
                           } // end forall i in SetCurF with (ref SetNextF) 
                           //writeln("Current frontier =",SetCurF);
                           //writeln("next    frontier =",SetNextF);
                      } //end on loc 
                  } //end coforall loc in Locales 
                  RemovedEdge+=SetNextF.getSize();
                  SetCurF<=>SetNextF;
                  SetNextF.clear();
                  //writeln("After Exchange");
                  //writeln("Current frontier =",SetCurF);
                  //writeln("next    frontier =",SetNextF);
              }// end of while (!SetCurF.isEmpty()) 
              N2+=1;
          }// end while (KeepCheck) 
          timer.stop();
          writeln("After Optimization,Total execution time=",timer.elapsed());
          writeln("After Optimization,Total number of iterations =",N2);
          writeln("After Optimization, Total Deleted edges using the new method=",RemovedEdge);
          //writeln("Saved number of iterations=",N1-N2);
          var tmpi=0;
          for i in 0..Ne-1 {
              if EdgeDeleted[i] {
                  //writeln("remove the ",tmpi, " edge ",i);
                  tmpi+=1;
              } else {
                  //writeln("keep the ",i, " = <", src[i],",",dst[i]," > edge ");
              }
          }
          writeln("Optimized version totally removed ",tmpi, " edges");
          return "completed";
      } // end of proc kTrussOpt(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                    
      proc kTrussInitVTwo(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
                        //Load Balance
                        //sync?
                        var srcComb = src;
                        var EdgeFlag=0: [0..Ne] int;
                        var k:int;
                        k=2;
                        var uadj = new set(int, parSafe = true);
	                var vadj = new set(int, parSafe = true); 
                        ref srcRef = src;
                        ref dstRef = dst;
                        var forwardVertice:int;
                        var reverseVertice:int;
                        var tricount:int;
                        

                        EdgeCnt= -1: [0..Ne-1] int; //Number of Triangles
   
                       
          
          		for i in 0..Ne-1 { //begin edge iteration
                           forwardVertice=src[i];
	                   reverseVertice=dst[i];
	                   uadj.clear();
                           vadj.clear();
                           tricount=0;
	                   if (EdgeFlag[i] != -1) {


			      for u in 0..Ne-1 { //begin edgelist iteration
			          if (EdgeFlag[u] == 0) {
				  if (srcRef[u] == forwardVertice) {
				      uadj.add(dstRef[u]); 
				  
				      }
				  if (srcRef[u] == reverseVertice) {
				      vadj.add(dstRef[u]);
				      } 
				  }//end edgelist iteration
				  }
			      for v in 0..Ne-1 {//begin reverse edgelist iteration
			          if (EdgeFlag[v] == 0) { 
				  if (dstRef[v] == forwardVertice) {
				      uadj.add(srcRef[v]);
				      }
				  if (dstRef[v] == reverseVertice) {
				      vadj.add(srcRef[v]);
				      }
				  }
				  }
 
			      for u in uadj {
				  if vadj.contains(u) {
				      tricount += 1;
				      }
				  }
				  EdgeCnt[i] = tricount;
				}
				
				//forwardvertice not -1
			      }//end edge iteration
                            
                         

                         writeln("first Triangle count");
                         writeln(EdgeCnt[5]);

                         forall e in 0..Ne-1 {
                            if (EdgeCnt[e] < k) {
                                //finalFrontier.add(e);
                                //srcRef[e] = -1;
                                //dstRef[e] = -1;
                                //EdgeFlag[e] = -1;
                                
                            }
                       }
                       
                       var checkFlag:int;
                       checkFlag = 1;
                       var temp:int;
                       //var testBag = new DistBag(int, Locales);
                       var frontier = new set(int, parSafe = true);
                       var finalFrontier= new set(int, parSafe = true);
                       for e in 0..Ne {
                           if (EdgeCnt[e] < k) {
                               if EdgeCnt[e] > 0 {
                               finalFrontier.add(e);
                               }
                           }
                           }
                       var numCurF:int;
                       numCurF=1;
                       var test:int;
                      
                       
                       
                       var triSet = new set((int,int,int), parSafe= true);
                      
                       var testints:int;
                       testints = 200;
                       
                       while(numCurF > 0) {
                       testints = testints -1;
                       //writeln("Next Iteration of variables ", finalFrontier);
                       forall temp in finalFrontier with (ref triSet, ref finalFrontier, ref frontier) {
                           //writeln("here is where we are ", temp, " ", srcRef[temp], " ", dstRef[temp]);
                           var adj: [0..Ne-1, 0..1] int;
                           adj = -1;
                           var uadjRef = new set(int, parSafe=true);
                           var vadjRef = new set(int, parSafe=true);
                           uadjRef.clear();
                           vadjRef.clear();
                           for u in 0..Ne-1 {
                               //if (EdgeFlag[u] != -1) {
                               if (srcRef[u] == srcRef[temp]) {
                               uadjRef.add(dstRef[u]);
                               adj[dstRef[u], 0] = u;
                               }
                               if (srcRef[u] == dstRef[temp]) {
                               vadjRef.add(dstRef[u]);
                               adj[dstRef[u], 0] = u;
                               }
                               //}
                               }
                           for v in 0..Ne-1 {
                               //if (EdgeFlag[v] != -1) {
                               if (dstRef[v] == srcRef[temp]) {
                               uadjRef.add(srcRef[v]);
                               adj[srcRef[v],1] = v;
                               

                               
                               }
                               if (dstRef[v] == dstRef[temp]) {
                               vadjRef.add(srcRef[v]);
                               adj[srcRef[v],1] = v;
                               
                               }
                             // }
                           }
                           
                           
                           for u in uadjRef {
                               if (vadjRef.contains(u)) {
                                   if (!(triSet.contains((u, srcRef[temp], dstRef[temp])) || triSet.contains((u, dstRef[temp], srcRef[temp])) || triSet.contains((dstRef[temp], srcRef[temp], u)) || triSet.contains((dstRef[temp], u, srcRef[temp])) || triSet.contains((srcRef[temp], dstRef[temp], u)) || triSet.contains((srcRef[temp], u, dstRef[temp])))) {
                                       //writeln("Hi we got here", temp);
                                       triSet.add((srcRef[temp], dstRef[temp],u));
                                       if (EdgeCnt[adj[u,0]] > 0) {
                                           EdgeCnt[adj[u,0]] = EdgeCnt[adj[u,0]] - 1;
                                           frontier.add(adj[u,0]);
                                           writeln("this is added ", adj[u,0]);
                                       }
                                       if (EdgeCnt[adj[u,1]] > 0) {
                                           EdgeCnt[adj[u,1]] = EdgeCnt[adj[u,1]] - 1;
                                           frontier.add(adj[u,1]);
                                           writeln("this is added ", adj[u,1]);
                                       }
                                       if (EdgeCnt[temp] > 0) {
                                           EdgeCnt[temp] = EdgeCnt[temp] - 1;
                                           frontier.add(temp);
                                       }
                                   }
                               }
                               }
                               
                           } 
                       finalFrontier.clear();
                           for e in frontier {
                               finalFrontier.add(e);
                           }
                           finalFrontier = frontier;
                           frontier.clear();
                       numCurF = finalFrontier.size;
                       //frontier.clear();
                       //writeln("End", numCurF, " ", finalFrontier);
                       }
                       var tempsetTwo = new set(int, parSafe = true);
                       for i in 0..Ne-1 {
                       if (EdgeCnt[i] >= k) {
                       tempsetTwo.add(i);
                       }
                       }
                       writeln("These are the triangles", tempsetTwo);
                       writeln("these are the counts", EdgeCnt);
             return "Indeed";
                        
      }
                        
      proc kTrussInit(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
                        //Load Balance
                        //sync?
                        var srcComb = src;
                        var EdgeFlag=0: [0..Ne] int;
                        var k:int;
                        k=2;
                        var uadj = new set(int, parSafe = true);
	                var vadj = new set(int, parSafe = true); 
                        ref srcRef = src;
                        ref dstRef = dst;
                        var forwardVertice:int;
                        var reverseVertice:int;
                        var tricount:int;
                        

                        EdgeCnt=0: [0..Ne] int; //Number of Triangles
   
                       
                   for j in 0..20 {
          		for i in 0..Ne-1 { //begin edge iteration
                           forwardVertice=src[i];
	                   reverseVertice=dst[i];
	                   uadj.clear();
                           vadj.clear();
                           tricount=0;
	                   if (EdgeFlag[i] != -1) {


			      for u in 0..Ne-1 { //begin edgelist iteration
			          if (EdgeFlag[u] == 0) {
				  if (srcRef[u] == forwardVertice) {
				      uadj.add(dstRef[u]); 
				  
				      }
				  if (srcRef[u] == reverseVertice) {
				      vadj.add(dstRef[u]);
				      } 
				  }//end edgelist iteration
				  }
			      for v in 0..Ne-1 {//begin reverse edgelist iteration
			          if (EdgeFlag[v] == 0) { 
				  if (dstRef[v] == forwardVertice) {
				      uadj.add(srcRef[v]);
				      }
				  if (dstRef[v] == reverseVertice) {
				      vadj.add(srcRef[v]);
				      }
				  }
				  }
 
			      for u in uadj {
				  if vadj.contains(u) {
				      tricount += 1;
				      }
				  }
				  EdgeCnt[i] = tricount;
				}
				
				//forwardvertice not -1
			      }//end edge iteration
                            
                        
                         if (j ==1) {
                         writeln("first Triangle count");
                         writeln(EdgeCnt[5]);
                         }
                         
                         forall e in 0..Ne-1 {
                            if (EdgeCnt[e] < k) {
                                
                                //srcRef[e] = -1;
                                //dstRef[e] = -1;
                                EdgeFlag[e] = -1;
                            }
                       }
             
             if (j == 49) {          
             writeln("Iterative Edge Count");
             forall g in 0..Ne-1 {
                 if (EdgeCnt[g] > 0) {
                 writeln(srcRef[g], "," , dstRef[g], " Tri Value ", EdgeCnt[g]);
                 }
             }
             }
             } 

            writeln("Success Final");
             return "Indeed";
                        
      }
        
      (srcN, dstN, startN, neighbourN,srcRN, dstRN, startRN, neighbourRN)= restpart.splitMsgToTuple(8);
      writeln("Some Vertices",neighbourRN);
      var ag = new owned SegGraphUD(Nv,Ne,Directed,Weighted,
                      srcN,dstN, startN,neighbourN,
                      srcRN,dstRN, startRN,neighbourRN,
                      st);

              //tri_edge_kernel(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
              //             ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a);
      kTrussNaive(kValue,ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a);
      kTrussOpt(kValue,ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a);
      writeln("Success");
      //timer.stop();
      proc return_tri_edge(): string throws{
          var TotalCnt=0:[0..0] int;
          TotalCnt[0]=0;
          var countName = st.nextName();
          var countEntry = new shared SymEntry(TotalCnt);
          st.addEntry(countName, countEntry);

          var cntMsg =  'created ' + st.attrib(countName);
          return cntMsg;

      }
      repMsg=return_tri_edge();
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }

  proc segTriMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var repMsg: string;
      var (n_verticesN,n_edgesN,directedN,weightedN,restpart )
          = payload.splitMsgToTuple(5);
      var Nv=n_verticesN:int;
      var Ne=n_edgesN:int;
      var Directed=directedN:int;
      var Weighted=weightedN:int;
      var countName:string;
      var timer:Timer;
      timer.start();

      var TotalCnt=0:[0..0] int;
      var subTriSum=0: [0..numLocales-1] int;
      var StartVerAry=-1: [0..numLocales-1] int;
      var EndVerAry=-1: [0..numLocales-1] int;
      var RemoteAccessTimes=0: [0..numLocales-1] int;
      var LocalAccessTimes=0: [0..numLocales-1] int;

      var srcN, dstN, startN, neighbourN,vweightN,eweightN, rootN :string;
      var srcRN, dstRN, startRN, neighbourRN:string;

      proc tri_kernel(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int):string throws{
            /*
            coforall loc in Locales  {
                   on loc {
                       var triCount=0:int;

                       ref srcf=src;
                       ref df=dst;
                       ref sf=start_i;
                       ref nf=nei;
                       var ld=srcf.localSubdomain();

                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       var aggsrc= newSrcAggregator(int);

                       if (startVer>0 && startEdge>0)  {//skip the first node if its  edges cover two locales
                            aggsrc.copy(lastVer,srcf[startEdge-1]);
                            aggsrc.flush();
                            while (lastVer==startVer) {
                                startEdge+=1;
                                aggsrc.copy(startVer,srcf[startEdge]);
                            } 
                       }

                       // the size can be larger than the number of all u
                       var uary:[0..srcf[endEdge]-srcf[startEdge]] int;
                       var uindex:int;
                       unidex=0;
                       uary[0]=srcf[0];
                       for i in startEdge+1..endEdge  {// build all nodes belong to the current locale
                             if (srcf[i] != uary[uindex]) {
                                 uindex+=1;
                                 uary[uindex]=srcf[i];         
                             } 
                       }

                       forall u in uary[0..uindex] {// for all the u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;
                           aggsrc.copy(startu_adj,sf[u]);
                           aggsrc.copy(endu_adj,sf[u]+nf[u]-1);
                           aggsrc.copy(numu_adj,nf[u]);
                           aggsrc.flush();

                           proc intersection_uv(uadj:[?D] int) {
                               var ui:int;
                               ui=0;
                               var vj:int;
                               vj=0;

                               while (ui<=endu_adj-startu_adj) {// for all u_adj
                                    v=uadj[ui+startu_adj];
                                    var startv_adj:int;
                                    var endv_adj:int;
                                    var numv_adj:int;
                                    aggsrc.copy(startv_adj,sf[v]);
                                    aggsrc.copy(endv_adj,sf[v]+nf[v]-1);
                                    aggsrc.copy(numv_adj,nf[v]);
                                    aggsrc.flush();

                                    proc intersection_v(vadj:[?D] int) {
                                        while (vj<=endv_adj-startv_adj) {// for all v_adj
                                             if (uadj[ui+startu_adj]==vadj[vj+startv_adj]) {
                                                 triCount+=1;
                                                 ui+=1;
                                                 vj+=1;                    
                                             } else {
                                                 if (uadj[ui]>vadj[vj]) {
                                                     vj+=1;
                                                 } else {
                                                     ui+=1;
                                                 }
                                             }
                                        }// end while
                                    }//end proc

                                    if (endv_adj<=df.localSubdomain().high && startv_adj>=df.localSubdomain().low){
                                         ref refvadj:df[startv_adj..endv_adj];
                                         intersection_v(refvadj);
                                    } else {
                                         var valuevadj:[numv_adj] int;
                                         forall (a,b) in zip(valuevadj,df[startv_adj..endv_adj]) with 
                                               (var agg= newSrcAggregator(int)) {
                                              agg.copy(a,b);
                                         }
                                         endv_adj=endv_adj-startv_adj;
                                         startv_adj=0;
                                         intersection_v(valuevadj);
                                    }// end if
                               }// end while
                           }// end proc

                           if (endu_adj<=df.localSubdomain().low){
                               ref refuadj=df[startu_adj..endu_adj];
                               intersection_uv(refuadj);
                           } else {
                               var valueuadj:[numu_adj] int;
                               forall (a,b) in zip(uadj,df[startu_adj..endu_adj]) 
                                      with (var agg= newSrcAggregator(int)) {
                                     agg.copy(a,b);
                               }
                               endu_adj=endu_adj-startu_adj;
                               startu_adj=0;
                               intersection_uv(valueuadj);
                           }
                       }//end forall u
                       subTriSum[here.id]+=triCount;
                       writeln("locale =",here.id,"subTriSum=",subTriSum);
                   }//end on loc
            }//end forall loc
            */
            return "success";
      }



      proc tri_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          coforall loc in Locales   {
                   on loc {
                       var triCount=0:int;
                       var remoteCnt=0:int;
                       var localCnt=0:int;
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var ld=srcf.localSubdomain();
                       var ldR=srcfR.localSubdomain();

                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       //writeln("1 Locale=",here.id, " local domain=", ld, ", Reverse local domain=",ldR);

                       if (here.id>0) {
                          if EndVerAry[here.id-1]==StartVerAry[here.id] {
                             startVer+=1;    
                          } else {
                             if (StartVerAry[here.id]-EndVerAry[here.id-1]>2 ){
                                startVer=EndVerAry[here.id-1]+1;
                             }
                          }
                       }
                       if (here.id==numLocales-1) {
                             endVer=nei.size-1;
                       }
                       if (here.id ==0 ) {
                          startVer=0;
                       }

                       //writeln("3 Locale=",here.id, " Updated Starting/End Vertex=[",startVer, ",", endVer, "], StarAry=", StartVerAry, " EndAry=", EndVerAry);
                       forall u in startVer..endVer with (+ reduce triCount,+ reduce remoteCnt, + reduce localCnt) {// for all the u
                           //writeln("4 Locale=",here.id, " u=",u, " Enter coforall path");
                           var uadj= new set(int,parSafe = true);
                           //var uadj= new set(int);
                           //var uadj=  new DistBag(int,Locales); //use bag to keep the adjacency of u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;

                           var startuR_adj:int;
                           var enduR_adj:int;
                           var numuR_adj:int;

                           var aggu= newSrcAggregator(int);
                           aggu.copy(startu_adj,sf[u]);
                           aggu.copy(endu_adj,sf[u]+nf[u]-1);
                           aggu.copy(numu_adj,nf[u]);

                           aggu.copy(startuR_adj,sfR[u]);
                           aggu.copy(enduR_adj,sfR[u]+nfR[u]-1);
                           aggu.copy(numuR_adj,nfR[u]);
                           aggu.flush();
                           //writeln("6 Locale=",here.id, " u[",startu_adj, ",",endu_adj, "], num=",numu_adj);

                           if (numu_adj>0) {
                               if (startu_adj>=ld.low && endu_adj<=ld.high) {
                                   forall i in df[startu_adj..endu_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add local ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numu_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startu_adj..endu_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add remote ",i);
                                      }
                                   }
                               }
                           }
                           if (numuR_adj>0) {
                               if (startuR_adj>=ldR.low && enduR_adj<=ldR.high) {
                                   forall i in dfR[startuR_adj..enduR_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         // writeln("8 Locale=",here.id,  " u=",u, " add reverse lodal ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numuR_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startuR_adj..enduR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,dfR[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("8 Locale=",here.id,  " u=",u, " add reverse remote ",i);
                                      }
                                   }

                               }

                           }// end of building uadj 
                           //writeln("9 Locale=",here.id, " u=",u," got uadj=",uadj, " numu_adj=", numu_adj," numuR_adj=", numuR_adj);

                           forall v in uadj with (+reduce triCount,ref uadj,+ reduce remoteCnt, + reduce localCnt) {
                               //writeln("10 Locale=",here.id, " u=",u," and v=",v, " enter forall");
                               var vadj= new set(int,parSafe = true);
                               //var vadj= new set(int);
                               //var vadj=  new DistBag(int,Locales); //use bag to keep the adjacency of v
                               var startv_adj:int;
                               var endv_adj:int;
                               var numv_adj:int;

                               var startvR_adj:int;
                               var endvR_adj:int;
                               var numvR_adj:int;

                               var aggv= newSrcAggregator(int);
                               aggv.copy(startv_adj,sf[v]);
                               aggv.copy(endv_adj,sf[v]+nf[v]-1);
                               aggv.copy(numv_adj,nf[v]);

                               aggv.copy(startvR_adj,sfR[v]);
                               aggv.copy(endvR_adj,sfR[v]+nfR[v]-1);
                               aggv.copy(numvR_adj,nfR[v]);
                               aggv.flush();

                               if (numv_adj>0) {
                                   if (startv_adj>=ld.low && endv_adj<=ld.high) {
                                       forall i in df[startv_adj..endv_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numv_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startv_adj..endv_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+ reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add remote ",i);
                                          }
                                       }

                                   }

                               }
                               if (numvR_adj>0) {
                                   if (startvR_adj>=ldR.low && endvR_adj<=ldR.high) {
                                       forall i in dfR[startvR_adj..endvR_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numvR_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startvR_adj..endvR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                                 agg.copy(a,dfR[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse remote ",i);
                                          }
                                       }

                                   }

                               }
                               //var triset= new set(int,parSafe=true);
                               //var triset= new set(int);
                               //triset=uadj & vadj;
                               //writeln("30 Locale=",here.id, " u=",u, " v=",v, " uadj=",uadj, " vadj=",vadj);
                               //var num=uadj.getSize();
                               var num=vadj.size;
                               forall i in vadj with (+ reduce triCount) {
                                   if uadj.contains(i) {
                                      triCount+=1;
                                   }
                               }
                               //writeln("31 Locale=",here.id, "tri=", triCount," u=",u, " v=",v);
                               //vadj.clear();
                           }// end forall v adj build
                           //uadj.clear();
                       }// end forall u adj build
                       subTriSum[here.id]=triCount;
                       RemoteAccessTimes[here.id]=remoteCnt;
                       LocalAccessTimes[here.id]=localCnt;
                       //writeln("100 Locale=",here.id, " subTriSum=", subTriSum);
                   }//end on loc
          }//end coforall loc
          return "success";
      }//end of tri_kernel_u


      proc return_tri_count(): string throws{
          for i in subTriSum {
             TotalCnt[0]+=i;
          }
          var totalRemote=0:int;
          var totalLocal=0:int;
          for i in RemoteAccessTimes {
              totalRemote+=i;
          }
          for i in LocalAccessTimes {
              totalLocal+=i;
          }
          //TotalCnt[0]/=3;
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("TriangleNumber=", TotalCnt[0]);
          writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
          writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          //writeln("1000 Locale=",here.id, " subTriSum=", subTriSum, "TotalCnt=",TotalCnt);
          var countName = st.nextName();
          var countEntry = new shared SymEntry(TotalCnt);
          st.addEntry(countName, countEntry);

          var cntMsg =  'created ' + st.attrib(countName);
          return cntMsg;

      }


      if (Directed!=0) {
          if (Weighted!=0) {
               (srcN, dstN, startN, neighbourN,vweightN,eweightN)=
                   restpart.splitMsgToTuple(6);
              var ag = new owned SegGraphDW(Nv,Ne,Directed,Weighted,srcN,dstN,
                                 startN,neighbourN,vweightN,eweightN, st);
              tri_kernel(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a);

          } else {

              (srcN, dstN, startN, neighbourN)=restpart.splitMsgToTuple(4);
              var ag = new owned SegGraphD(Nv,Ne,Directed,Weighted,srcN,dstN,
                      startN,neighbourN,st);
              tri_kernel(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a);
          }
      }
      else {
          if (Weighted!=0) {
               (srcN, dstN, startN, neighbourN,srcRN, dstRN, startRN, neighbourRN,vweightN,eweightN)=
                   restpart.splitMsgToTuple(10);
               var ag = new owned SegGraphUDW(Nv,Ne,Directed,Weighted,
                      srcN,dstN, startN,neighbourN,
                      srcRN,dstRN, startRN,neighbourRN,
                      vweightN,eweightN, st);
              tri_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a);
          } else {
              (srcN, dstN, startN, neighbourN,srcRN, dstRN, startRN, neighbourRN)=
                   restpart.splitMsgToTuple(8);
              var ag = new owned SegGraphUD(Nv,Ne,Directed,Weighted,
                      srcN,dstN, startN,neighbourN,
                      srcRN,dstRN, startRN,neighbourRN,
                      st);

              tri_kernel_u(ag.neighbour.a, ag.start_i.a,ag.src.a,ag.dst.a,
                           ag.neighbourR.a, ag.start_iR.a,ag.srcR.a,ag.dstR.a);
          }
      }
      repMsg=return_tri_count();
      timer.stop();
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);
  }





// directly read a stream from given file and build the SegGraph class in memory
  proc segStreamTriCntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var (NeS,NvS,ColS,DirectedS, FileName,FactorS) = payload.splitMsgToTuple(6);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var Factor=FactorS:int;
      var StreamNe=Ne/Factor:int;
      var StreamNv=Nv/Factor:int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      if NumCol>2 {
           weighted=1;
      }

      timer.start();
      var src=makeDistArray(StreamNe,int);
      var dst=makeDistArray(StreamNe,int);
      //var length=makeDistArray(StreamNv,int);
      var neighbour=makeDistArray(StreamNv,int);
      var start_i=makeDistArray(StreamNv,int);

      var e_weight = makeDistArray(StreamNe,int);
      var e_cnt = makeDistArray(StreamNe,int);
      var v_weight = makeDistArray(StreamNv,int);
      var v_cnt = makeDistArray(StreamNv,int);

      var iv=makeDistArray(StreamNe,int);

      var srcR=makeDistArray(StreamNe,int);
      var dstR=makeDistArray(StreamNe,int);
      var neighbourR=makeDistArray(StreamNv,int);
      var start_iR=makeDistArray(StreamNv,int);
      ref  ivR=iv;

      var linenum=0:int;

      var repMsg: string;

      var startpos, endpos:int;
      var sort_flag:int;
      var filesize:int;

      var TotalCnt=0:[0..0] int;
      var subTriSum=0: [0..numLocales-1] int;
      var StartVerAry=-1: [0..numLocales-1] int;
      var EndVerAry=-1: [0..numLocales-1] int;
      var RemoteAccessTimes=0: [0..numLocales-1] int;
      var LocalAccessTimes=0: [0..numLocales-1] int;



      proc readLinebyLine() throws {
           coforall loc in Locales  {
              on loc {
                  var randv = new RandomStream(real, here.id, false);
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var Streamcurline=0:int;
                  var srclocal=src.localSubdomain();
                  var neilocal=neighbour.localSubdomain();
                  var ewlocal=e_weight.localSubdomain();
                  forall i in srclocal {
                        src[i]=-1;
                        dst[i]=-1;
                        srcR[i]=-1;
                        dstR[i]=-1;
                        e_weight[i]=0;
                        e_cnt[i]=0;
                  }
                  forall i in neilocal {
                        neighbour[i]=0;
                        neighbourR[i]=0;
                        v_weight[i]=0;
                        v_cnt[i]=0;
                        start_i[i]=-1;
                        start_iR[i]=-1;
                  }

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            //if ewlocal.contains(Streamcurline){
                            //    e_weight[Streamcurline]=c:int;
                            //}
                      }
                      var a_hash=(a:int) % StreamNv;
                      var b_hash=(b:int) % StreamNv;
                      if srclocal.contains(Streamcurline) {
                          //if ((curline<StreamNe) || (randv.getNext()>= 1.0/Factor:real) ) {
                              src[Streamcurline]=a_hash;
                              dst[Streamcurline]=b_hash;
                              e_cnt[Streamcurline]+=1;
                          //}
                      }
                      if neilocal.contains(a_hash) {
                          v_cnt[a_hash]+=1;
                      }
                      if neilocal.contains(b_hash) {
                          v_cnt[b_hash]+=1;
                      }
                      curline+=1;
                      Streamcurline=curline%StreamNe;
                  } 
                  forall i in src.localSubdomain() {
                       src[i]=src[i]+(src[i]==dst[i]);
                       src[i]=src[i]%StreamNv;
                       dst[i]=dst[i]%StreamNv;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
      }//end readLinebyLine
      
      readLinebyLine();
      //start_i=-1;
      //start_iR=-1;
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      timer.start();

      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  4 { 
                      iv = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32) {    
                      return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             tmpedges=e_cnt[iv];
             e_cnt=tmpedges;

             return "success";
      }//end combine_sort

      proc set_neighbour(){ 
          coforall loc in Locales  {
              on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;
                       var ld=srcf.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       forall i in startEdge..endEdge {
                          var srci=src[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbour[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbour[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newDstAggregator(int);
                              aggd.copy(neighbour[srci],tmpn);
                              aggd.flush();
                          }

                       }

              }
          }
          for i in 0..StreamNe-1 do {
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }

      combine_sort();
      set_neighbour();

      if (directed==0) { //undirected graph

          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  4 { 
                      ivR = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }

             var tmpedges = srcR[ivR]; 
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";

          }// end combine_sortR


          proc set_neighbourR(){ 
              coforall loc in Locales  {
                  on loc {
                       ref srcfR=srcR;
                       ref nfR=neighbourR;
                       ref sfR=start_iR;
                       var ldR=srcfR.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcfR[ldR.low];
                       var endVer=srcfR[ldR.high];

                       var startEdge=ldR.low;
                       var endEdge=ldR.high;

                       forall i in startEdge..endEdge {
                          var srci=srcR[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbourR[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbourR[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newSrcAggregator(int);
                              aggd.copy(neighbourR[srci],tmpn);
                              aggd.flush();
                          }

                       }

                  }//on loc
              }//coforall
              for i in 0..StreamNe-1 do {
                 if (start_iR[srcR[i]] ==-1){
                     start_iR[srcR[i]]=i;
                 }
              }
          }


          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          combine_sortR();
          set_neighbourR();

      }//end of undirected

      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");



      timer.start();

      coforall loc in Locales  {
              on loc {
                  forall i in neighbour.localSubdomain(){
                      if ( v_cnt[i]<=1 ) {
                          neighbour[i]=0;
                          neighbourR[i]=0;
                      }
                  }
              }
      }
      proc stream_tri_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var number_edge=0:int;
          var sum_ratio1=0.0:real;
          var sum_ratio2=0.0:real;
          coforall loc in Locales with (+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2)  {
                   on loc {
                       var triCount=0:int;
                       var remoteCnt=0:int;
                       var localCnt=0:int;
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var ld=srcf.localSubdomain();
                       var ldR=srcfR.localSubdomain();

                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       //writeln("1 Locale=",here.id, " local domain=", ld, ", Reverse local domain=",ldR);

                       if (here.id>0) {
                          if EndVerAry[here.id-1]==StartVerAry[here.id] {
                             startVer+=1;    
                          } else {
                             if (StartVerAry[here.id]-EndVerAry[here.id-1]>2 ){
                                startVer=EndVerAry[here.id-1]+1;
                             }
                          }
                       }
                       if (here.id==numLocales-1) {
                             endVer=nei.size-1;
                       }
                       if (here.id ==0 ) {
                          startVer=0;
                       }

                       //writeln("3 Locale=",here.id, " Updated Starting/End Vertex=[",startVer, ",", endVer, "], StarAry=", StartVerAry, " EndAry=", EndVerAry);
                       forall u in startVer..endVer with (+ reduce triCount,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {// for all the u
                           //writeln("4 Locale=",here.id, " u=",u, " Enter coforall path");
                           var uadj= new set(int,parSafe = true);
                           //var uadj= new set(int);
                           //var uadj=  new DistBag(int,Locales); //use bag to keep the adjacency of u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;

                           var startuR_adj:int;
                           var enduR_adj:int;
                           var numuR_adj:int;

                           var aggu= newSrcAggregator(int);
                           aggu.copy(startu_adj,sf[u]);
                           aggu.copy(endu_adj,sf[u]+nf[u]-1);
                           aggu.copy(numu_adj,nf[u]);

                           aggu.copy(startuR_adj,sfR[u]);
                           aggu.copy(enduR_adj,sfR[u]+nfR[u]-1);
                           aggu.copy(numuR_adj,nfR[u]);
                           aggu.flush();
                           //writeln("6 Locale=",here.id, " u[",startu_adj, ",",endu_adj, "], num=",numu_adj);

                           if (numu_adj>0) {
                               if (startu_adj>=ld.low && endu_adj<=ld.high) {
                                   forall i in df[startu_adj..endu_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add local ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numu_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startu_adj..endu_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add remote ",i);
                                      }
                                   }
                               }
                           }
                           if (numuR_adj>0) {
                               if (startuR_adj>=ldR.low && enduR_adj<=ldR.high) {
                                   forall i in dfR[startuR_adj..enduR_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         // writeln("8 Locale=",here.id,  " u=",u, " add reverse lodal ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numuR_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startuR_adj..enduR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,dfR[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("8 Locale=",here.id,  " u=",u, " add reverse remote ",i);
                                      }
                                   }

                               }

                           }// end of building uadj 
                           //writeln("9 Locale=",here.id, " u=",u," got uadj=",uadj, " numu_adj=", numu_adj," numuR_adj=", numuR_adj);

                           forall v in uadj with (+reduce triCount,ref uadj,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {
                               //writeln("10 Locale=",here.id, " u=",u," and v=",v, " enter forall");
                               var vadj= new set(int,parSafe = true);
                               //var vadj= new set(int);
                               //var vadj=  new DistBag(int,Locales); //use bag to keep the adjacency of v
                               var startv_adj:int;
                               var endv_adj:int;
                               var numv_adj:int;

                               var startvR_adj:int;
                               var endvR_adj:int;
                               var numvR_adj:int;

                               var aggv= newSrcAggregator(int);
                               aggv.copy(startv_adj,sf[v]);
                               aggv.copy(endv_adj,sf[v]+nf[v]-1);
                               aggv.copy(numv_adj,nf[v]);

                               aggv.copy(startvR_adj,sfR[v]);
                               aggv.copy(endvR_adj,sfR[v]+nfR[v]-1);
                               aggv.copy(numvR_adj,nfR[v]);
                               aggv.flush();

                               if (numv_adj>0) {
                                   if (startv_adj>=ld.low && endv_adj<=ld.high) {
                                       forall i in df[startv_adj..endv_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numv_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startv_adj..endv_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+ reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add remote ",i);
                                          }
                                       }

                                   }

                               }
                               if (numvR_adj>0) {
                                   if (startvR_adj>=ldR.low && endvR_adj<=ldR.high) {
                                       forall i in dfR[startvR_adj..endvR_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numvR_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startvR_adj..endvR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                                 agg.copy(a,dfR[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse remote ",i);
                                          }
                                       }

                                   }

                               }
                               //var triset= new set(int,parSafe=true);
                               //var triset= new set(int);
                               //triset=uadj & vadj;
                               //writeln("30 Locale=",here.id, " u=",u, " v=",v, " uadj=",uadj, " vadj=",vadj);
                               //var num=uadj.getSize();
                               var num=vadj.size;
                               var localtricnt=0:int;
                               forall i in vadj with (+ reduce triCount,+reduce localtricnt) {
                                   if uadj.contains(i) {
                                      triCount+=1;
                                      localtricnt+=1;
                                   }
                               }
                               if (localtricnt>0) {
                                   number_edge+=1;
                                   sum_ratio1+=(v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real;
                                   sum_ratio2+=(v_cnt[u]+v_cnt[v]):real/(neighbour[u]+neighbourR[u]+neighbour[v]+neighbourR[v]):real;
                                   //writeln("3333 Locale=",here.id, " tri=", localtricnt," u=",u, " v=",v, " u_cnt=", v_cnt[u], " v_cnt=", v_cnt[v], " ratio=", (v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real);
                               }
                               //writeln("31 Locale=",here.id, "tri=", triCount," u=",u, " v=",v);
                               //vadj.clear();
                           }// end forall v adj build
                           //uadj.clear();
                       }// end forall u adj build
                       subTriSum[here.id]=triCount;
                       RemoteAccessTimes[here.id]=remoteCnt;
                       LocalAccessTimes[here.id]=localCnt;
                       //writeln("100 Locale=",here.id, " subTriSum=", subTriSum);
                   }//end on loc
          }//end coforall loc
          var averageratio1=sum_ratio1/number_edge/2;
          var averageratio2=sum_ratio2/number_edge;
          writeln("Average ratio1=", averageratio1, " Total number of edges=",number_edge);
          writeln("Average ratio2=", averageratio2, " Total number of edges=",number_edge);
          var totaltri=0;
          for i in subTriSum {
             totaltri+=i;
          }
          writeln("Estimated triangles 1=",totaltri*Factor*max(1,averageratio1**(0.02)));
          writeln("Estimated triangles 2=",totaltri*Factor*max(1,averageratio2**(0.1)));
          writeln("Estimated triangles 3=",totaltri*Factor*max(1,averageratio2**(0.05)));
          writeln("Estimated triangles 4=",totaltri*Factor*max(1,averageratio2**(0.01)));
          return "success";
      }//end of stream_tri_kernel_u


      proc return_stream_tri_count(): string throws{
          for i in subTriSum {
             TotalCnt[0]+=i;
          }
          var totalRemote=0:int;
          var totalLocal=0:int;
          for i in RemoteAccessTimes {
              totalRemote+=i;
          }
          for i in LocalAccessTimes {
              totalLocal+=i;
          }
          //TotalCnt[0]/=3;
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("TriangleNumber=", TotalCnt[0]);
          writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
          writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          //writeln("1000 Locale=",here.id, " subTriSum=", subTriSum, "TotalCnt=",TotalCnt);
          var countName = st.nextName();
          var countEntry = new shared SymEntry(TotalCnt);
          st.addEntry(countName, countEntry);

          var cntMsg =  'created ' + st.attrib(countName);
          return cntMsg;

      }//end of proc return_stream


      stream_tri_kernel_u(neighbour, start_i,src,dst,
                           neighbourR, start_iR,srcR,dstR);
      repMsg=return_stream_tri_count();
      
      timer.stop();
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Streaming Triangle Counting time= ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);

  }






// directly read a stream from given file and build the SegGraph class in memory
  proc segStreamPLTriCntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var (NeS,NvS,ColS,DirectedS, FileName,FactorS, CaseS) = payload.splitMsgToTuple(7);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var Factor=FactorS:int;
      var NumSketch=3:int;// head, middle, and tail three parts as different sketchs
      var StreamNe=Ne/(Factor*NumSketch):int;
      var StreamNv=Nv/(Factor*NumSketch):int;
      var CaseNum=CaseS:int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      if NumCol>2 {
           weighted=1;
      }
      writeln("StreamNe=",StreamNe, " StreameNv=",StreamNv);

      timer.start();
      var src=makeDistArray(StreamNe,int);
      var dst=makeDistArray(StreamNe,int);
      var neighbour=makeDistArray(StreamNv,int);
      var start_i=makeDistArray(StreamNv,int);
      var e_weight = makeDistArray(StreamNe,int);
      var e_cnt = makeDistArray(StreamNe,int);
      var v_weight = makeDistArray(StreamNv,int);
      var v_cnt = makeDistArray(StreamNv,int);
      var iv=makeDistArray(StreamNe,int);

      var src1=makeDistArray(StreamNe,int);
      var dst1=makeDistArray(StreamNe,int);
      var neighbour1=makeDistArray(StreamNv,int);
      var start_i1=makeDistArray(StreamNv,int);
      var e_weight1 = makeDistArray(StreamNe,int);
      var e_cnt1 = makeDistArray(StreamNe,int);
      var v_weight1 = makeDistArray(StreamNv,int);
      var v_cnt1 = makeDistArray(StreamNv,int);
      var iv1=makeDistArray(StreamNe,int);
      var srcR1=makeDistArray(StreamNe,int);
      var dstR1=makeDistArray(StreamNe,int);
      var neighbourR1=makeDistArray(StreamNv,int);
      var start_iR1=makeDistArray(StreamNv,int);
      ref  ivR1=iv1;
      ref  iv2=iv1;
      ref  ivR2=iv1;
      ref  iv3=iv1;
      ref  ivR3=iv1;



      var src2=makeDistArray(StreamNe,int);
      var dst2=makeDistArray(StreamNe,int);
      var neighbour2=makeDistArray(StreamNv,int);
      var start_i2=makeDistArray(StreamNv,int);
      var e_weight2 = makeDistArray(StreamNe,int);
      var e_cnt2 = makeDistArray(StreamNe,int);
      var v_weight2 = makeDistArray(StreamNv,int);
      var v_cnt2 = makeDistArray(StreamNv,int);
      //var iv2=makeDistArray(StreamNe,int);
      var srcR2=makeDistArray(StreamNe,int);
      var dstR2=makeDistArray(StreamNe,int);
      var neighbourR2=makeDistArray(StreamNv,int);
      var start_iR2=makeDistArray(StreamNv,int);
      //ref  ivR2=iv2;


      var src3=makeDistArray(StreamNe,int);
      var dst3=makeDistArray(StreamNe,int);
      var neighbour3=makeDistArray(StreamNv,int);
      var start_i3=makeDistArray(StreamNv,int);
      var e_weight3 = makeDistArray(StreamNe,int);
      var e_cnt3 = makeDistArray(StreamNe,int);
      var v_weight3 = makeDistArray(StreamNv,int);
      var v_cnt3 = makeDistArray(StreamNv,int);
      //var iv3=makeDistArray(StreamNe,int);
      var srcR3=makeDistArray(StreamNe,int);
      var dstR3=makeDistArray(StreamNe,int);
      var neighbourR3=makeDistArray(StreamNv,int);
      var start_iR3=makeDistArray(StreamNv,int);
      //ref  ivR3=iv3;

      var linenum=0:int;
      var repMsg: string;
      var sort_flag:int;
      var filesize:int;

      var TotalCnt=0:[0..0] int;
      //var subTriSum=0: [0..numLocales-1] int;
      //var StartVerAry=-1: [0..numLocales-1] int;
      //var EndVerAry=-1: [0..numLocales-1] int;
      //var RemoteAccessTimes=0: [0..numLocales-1] int;
      //var LocalAccessTimes=0: [0..numLocales-1] int;


      //var TotalCnt1=0:[0..0] int;
      var subTriSum1=0: [0..numLocales-1] int;
      var StartVerAry1=-1: [0..numLocales-1] int;
      var EndVerAry1=-1: [0..numLocales-1] int;
      var RemoteAccessTimes1=0: [0..numLocales-1] int;
      var LocalAccessTimes1=0: [0..numLocales-1] int;


      //var TotalCnt2=0:[0..0] int;
      var subTriSum2=0: [0..numLocales-1] int;
      var StartVerAry2=-1: [0..numLocales-1] int;
      var EndVerAry2=-1: [0..numLocales-1] int;
      var RemoteAccessTimes2=0: [0..numLocales-1] int;
      var LocalAccessTimes2=0: [0..numLocales-1] int;

      //var TotalCnt3=0:[0..0] int;
      var subTriSum3=0: [0..numLocales-1] int;
      var StartVerAry3=-1: [0..numLocales-1] int;
      var EndVerAry3=-1: [0..numLocales-1] int;
      var RemoteAccessTimes3=0: [0..numLocales-1] int;
      var LocalAccessTimes3=0: [0..numLocales-1] int;

      proc readLinebyLine() throws {
           coforall loc in Locales  {
              on loc {
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var Streamcurline=0:int;
                  var edgedomain=src1.localSubdomain();
                  var nodedomain=neighbour1.localSubdomain();
                  //writeln("Locale ID=",here.id," edge local domain=", edgedomain, " node local domain=",nodedomain);
                  proc initvalue(ref ary:[?D1] int,intvalue:int) {
                      //writeln("Locale ID=",here.id, " sub domain=", ary.localSubdomain());
                      forall i in ary.localSubdomain() {
                         ary[i]=intvalue;
                      }
                  }
                  initvalue(src1,-1);
                  initvalue(dst1,-1);
                  initvalue(srcR1,-1);
                  initvalue(dstR1,-1);
                  initvalue(e_weight1,0);
                  initvalue(e_cnt1,0);

                  initvalue(src2,-1);
                  initvalue(dst2,-1);
                  initvalue(srcR2,-1);
                  initvalue(dstR2,-1);
                  initvalue(e_weight2,0);
                  initvalue(e_cnt2,0);

                  initvalue(src3,-1);
                  initvalue(dst3,-1);
                  initvalue(srcR3,-1);
                  initvalue(dstR3,-1);
                  initvalue(e_weight3,0);
                  initvalue(e_cnt3,0);


                  initvalue(neighbour1,0);
                  initvalue(neighbourR1,0);
                  initvalue(v_weight1,0);
                  initvalue(v_cnt1,0);
                  initvalue(start_i1,-1);
                  initvalue(start_iR1,-1);


                  initvalue(neighbour2,0);
                  initvalue(neighbourR2,0);
                  initvalue(v_weight2,0);
                  initvalue(v_cnt2,0);
                  initvalue(start_i2,-1);
                  initvalue(start_iR2,-1);


                  initvalue(neighbour3,0);
                  initvalue(neighbourR3,0);
                  initvalue(v_weight3,0);
                  initvalue(v_cnt3,0);
                  initvalue(start_i3,-1);
                  initvalue(start_iR3,-1);

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            //if ewlocal.contains(Streamcurline){
                            //    e_weight[Streamcurline]=c:int;
                            //}
                      }
                      var a_hash=(a:int) % StreamNv;
                      var b_hash=(b:int) % StreamNv;
                      if edgedomain.contains(Streamcurline) {
                          if (curline<(Ne/3):int) {
                              src1[Streamcurline]=a_hash;
                              dst1[Streamcurline]=b_hash;
                          } else {
                              if (curline>=(Ne*2/3):int) {
                                  src3[Streamcurline]=a_hash;
                                  dst3[Streamcurline]=b_hash;
                               } else {
                                  src2[Streamcurline]=a_hash;
                                  dst2[Streamcurline]=b_hash;
                               }
                          }
                      }

                      if nodedomain.contains(a_hash) {
                          if (curline<(Ne/3):int) {
                              v_cnt1[a_hash]+=1;
                          } else {
                              if (curline>(Ne*2/3):int) {
                                 v_cnt3[a_hash]+=1;
                              } else {
                                 v_cnt2[a_hash]+=1;
                              }
                          }
                      }
                      if nodedomain.contains(b_hash) {
                          if (curline<(Ne/3):int) {
                              v_cnt1[b_hash]+=1;
                          } else {
                              if (curline>(Ne*2/3):int) {
                                 v_cnt3[b_hash]+=1;
                              } else {
                                 v_cnt2[b_hash]+=1;
                              }
                          }
                      }

                      curline+=1;
                      Streamcurline=curline%StreamNe;
                  }
 
                  forall i in edgedomain {
                       src1[i]=src1[i]+(src1[i]==dst1[i]);
                       src1[i]=src1[i]%StreamNv;
                       dst1[i]=dst1[i]%StreamNv;

                       src2[i]=src2[i]+(src2[i]==dst2[i]);
                       src2[i]=src2[i]%StreamNv;
                       dst2[i]=dst2[i]%StreamNv;


                       src3[i]=src3[i]+(src3[i]==dst3[i]);
                       src3[i]=src3[i]%StreamNv;
                       dst3[i]=dst3[i]%StreamNv;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
      }//end readLinebyLine
      
      readLinebyLine();
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      timer.start();
      //writeln("src1=",src1," dst1=",dst1);
      //writeln("neighbour1=",neighbour1," start_i1=",start_i1);
      //writeln("v_cnt1=",v_cnt1 );

      //writeln("src2=",src2," dst2=",dst2);
      //writeln("neighbour2=",neighbour2," start_i2=",start_i2);
      //writeln("v_cnt2=",v_cnt2 );

      //writeln("src3=",src3," dst3=",dst3);
      //writeln("neighbour3=",neighbour3," start_i3=",start_i3);
      //writeln("v_cnt3=",v_cnt3 );

  
      //proc combine_sort(ref src:[?D1] int, ref dst:[?D2] int, ref iv:[?D3] int) throws {
      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits=0: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       //writeln("bitWidth=",bitWidth," neg=",neg);
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             //writeln("total digits=",totalDigits);
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    //writeln("curDigit=",curDigit);
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     //writeln("merged element=",m," a=",a);
                                     //writeln("curDigit=", curDigit, " myDigit=", myDigit);
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                     //writeln("m[curDigit+myDigit] =",m[curDigit+myDigit] );
                                 }
                            }
                            curDigit += r.size;
                            //writeln("curDigit=",curDigit, " r.size=",r.size);
                        }
                        mergeArray(int); 
                    }
                    //writeln("after merge=",merged);
                    //var tmpiv = argsortDefault(merged);
                    //writeln("after sort iv=",tmpiv);
                    return  argsortDefault(merged);
                    //return tmpiv;
             }

             if totalDigits ==  2 { 
                      //writeln("Before merged sort");
                      iv = mergedArgsort( 2); 
                      //writeln("after merged sort");
             }

             //writeln("before assign src to tmpedges");
             //writeln("src=",src);
             //writeln("iv=",iv);
             //writeln("src[iv]=",src[iv]);
             var tmpedges=src[iv];
             src=tmpedges;
             //writeln("after assign src to tmpedges");
             tmpedges=dst[iv];
             dst=tmpedges;
             //writeln("after assign dst to tmpedges");

      }//end combine_sort

      //proc set_neighbour(ref src:[?D1] int,ref  dst:[?D2] int,ref  neighbour:[?D3] int,ref start_i:[?D4] int) {
      proc set_neighbour() {
          coforall loc in Locales  {
              on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;
                       var ld=src.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       forall i in startEdge..endEdge {
                          var srci=src[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbour[srci]+=1;
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbour[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newDstAggregator(int);
                              aggd.copy(neighbour[srci],tmpn);
                              aggd.flush();
                          }
                       }
              }
          }
          for i in 0..StreamNe-1 do {
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }
      proc sameshape_array_assignment(A:[?D1],B:[?D2]) {
          coforall loc in Locales  {
              on loc {
                  forall i in A.localSubdomain(){
                       A[i]=B[i];
                  }
              }
          }
      }

      sameshape_array_assignment(src,src1);
      sameshape_array_assignment(dst,dst1);
      combine_sort();
      sameshape_array_assignment(neighbour,neighbour1);
      sameshape_array_assignment(start_i,start_i1);
      set_neighbour();
      sameshape_array_assignment(src1,src);
      sameshape_array_assignment(dst1,dst);
      sameshape_array_assignment(neighbour1,neighbour);
      sameshape_array_assignment(start_i1,start_i);


      sameshape_array_assignment(src,src2);
      sameshape_array_assignment(dst,dst2);
      combine_sort();
      sameshape_array_assignment(neighbour,neighbour2);
      sameshape_array_assignment(start_i,start_i2);
      set_neighbour();
      sameshape_array_assignment(src2,src);
      sameshape_array_assignment(dst2,dst);
      sameshape_array_assignment(neighbour2,neighbour);
      sameshape_array_assignment(start_i2,start_i);

      sameshape_array_assignment(src,src3);
      sameshape_array_assignment(dst,dst3);
      combine_sort();
      sameshape_array_assignment(neighbour,neighbour3);
      sameshape_array_assignment(start_i,start_i3);
      set_neighbour();
      sameshape_array_assignment(src3,src);
      sameshape_array_assignment(dst3,dst);
      sameshape_array_assignment(neighbour3,neighbour);
      sameshape_array_assignment(start_i3,start_i);



      sameshape_array_assignment(srcR1,dst1);
      sameshape_array_assignment(dstR1,src1);
      sameshape_array_assignment(srcR2,dst2);
      sameshape_array_assignment(dstR2,src2);
      sameshape_array_assignment(srcR3,dst3);
      sameshape_array_assignment(dstR3,src3);

      //coforall loc in Locales  {
      //        on loc {
      //            forall i in srcR1.localSubdomain(){
      //                  srcR1[i]=dst1[i];
      //                  dstR1[i]=src1[i];

      //                  srcR2[i]=dst2[i];
      //                  dstR2[i]=src2[i];

      //                  srcR3[i]=dst3[i];
      //                  dstR3[i]=src3[i];
      //             }
      //        }
      //}



      sameshape_array_assignment(src,srcR1);
      sameshape_array_assignment(dst,dstR1);
      combine_sort();
      sameshape_array_assignment(neighbour,neighbourR1);
      sameshape_array_assignment(start_i,start_iR1);
      set_neighbour();
      sameshape_array_assignment(srcR1,src);
      sameshape_array_assignment(dstR1,dst);
      sameshape_array_assignment(neighbourR1,neighbour);
      sameshape_array_assignment(start_iR1,start_i);


      sameshape_array_assignment(src,srcR2);
      sameshape_array_assignment(dst,dstR2);
      combine_sort();
      sameshape_array_assignment(neighbour,neighbourR2);
      sameshape_array_assignment(start_i,start_iR2);
      set_neighbour();
      sameshape_array_assignment(srcR2,src);
      sameshape_array_assignment(dstR2,dst);
      sameshape_array_assignment(neighbourR2,neighbour);
      sameshape_array_assignment(start_iR2,start_i);

      sameshape_array_assignment(src,srcR3);
      sameshape_array_assignment(dst,dstR3);
      combine_sort();
      sameshape_array_assignment(neighbour,neighbourR3);
      sameshape_array_assignment(start_i,start_iR3);
      set_neighbour();
      sameshape_array_assignment(srcR3,src);
      sameshape_array_assignment(dstR3,dst);
      sameshape_array_assignment(neighbourR3,neighbour);
      sameshape_array_assignment(start_iR3,start_i);


      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");



      timer.start();

      coforall loc in Locales  {
              on loc {
                  forall i in neighbour1.localSubdomain(){
                      if ( v_cnt1[i]<=1 ) {
                          neighbour1[i]=0;
                          neighbourR1[i]=0;
                      }
                      if ( v_cnt2[i]<=1 ) {
                          neighbour2[i]=0;
                          neighbourR2[i]=0;
                      }
                      if ( v_cnt3[i]<=1 ) {
                          neighbour3[i]=0;
                          neighbourR3[i]=0;
                      }
                  }
              }
      }

      proc stream_tri_kernel_u(neighbour:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neighbourR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int,
                        StartVerAry:[?D5] int, EndVerAry:[?D6] int,subTriSum:[?D7] int,
                        RemoteAccessTimes:[?D8] int,LocalAccessTimes:[?D9] int,v_cnt:[?D10] int  ):int throws{

          var number_edge=0:int;
          var sum_ratio1=0.0:real;
          var sum_ratio2=0.0:real;
          coforall loc in Locales with (+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2)  {
                   on loc {
                       var triCount=0:int;
                       var remoteCnt=0:int;
                       var localCnt=0:int;
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neighbourR;
                       ref sfR=start_iR;

                       var ld=srcf.localSubdomain();
                       var ldR=srcfR.localSubdomain();

                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       //writeln("1 Locale=",here.id, " local domain=", ld, ", Reverse local domain=",ldR);

                       if (here.id>0) {
                          if EndVerAry[here.id-1]==StartVerAry[here.id] {
                             startVer+=1;    
                          } else {
                             if (StartVerAry[here.id]-EndVerAry[here.id-1]>2 ){
                                startVer=EndVerAry[here.id-1]+1;
                             }
                          }
                       }
                       if (here.id==numLocales-1) {
                             endVer=neighbour.size-1;
                       }
                       if (here.id ==0 ) {
                          startVer=0;
                       }

                       //writeln("3 Locale=",here.id, " Updated Starting/End Vertex=[",startVer, ",", endVer, "], StarAry=", StartVerAry, " EndAry=", EndVerAry);
                       forall u in startVer..endVer with (+ reduce triCount,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {// for all the u
                           //writeln("4 Locale=",here.id, " u=",u, " Enter coforall path");
                           var uadj= new set(int,parSafe = true);
                           //var uadj= new set(int);
                           //var uadj=  new DistBag(int,Locales); //use bag to keep the adjacency of u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;

                           var startuR_adj:int;
                           var enduR_adj:int;
                           var numuR_adj:int;

                           var aggu= newSrcAggregator(int);
                           aggu.copy(startu_adj,sf[u]);
                           aggu.copy(endu_adj,sf[u]+nf[u]-1);
                           aggu.copy(numu_adj,nf[u]);

                           aggu.copy(startuR_adj,sfR[u]);
                           aggu.copy(enduR_adj,sfR[u]+nfR[u]-1);
                           aggu.copy(numuR_adj,nfR[u]);
                           aggu.flush();
                           //writeln("6 Locale=",here.id, " u[",startu_adj, ",",endu_adj, "], num=",numu_adj);

                           if (numu_adj>0) {
                               if (startu_adj>=ld.low && endu_adj<=ld.high) {
                                   forall i in df[startu_adj..endu_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add local ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numu_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startu_adj..endu_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add remote ",i);
                                      }
                                   }
                               }
                           }
                           if (numuR_adj>0) {
                               if (startuR_adj>=ldR.low && enduR_adj<=ldR.high) {
                                   forall i in dfR[startuR_adj..enduR_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         // writeln("8 Locale=",here.id,  " u=",u, " add reverse lodal ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numuR_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startuR_adj..enduR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,dfR[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("8 Locale=",here.id,  " u=",u, " add reverse remote ",i);
                                      }
                                   }

                               }

                           }// end of building uadj 
                           //writeln("9 Locale=",here.id, " u=",u," got uadj=",uadj, " numu_adj=", numu_adj," numuR_adj=", numuR_adj);

                           forall v in uadj with (+reduce triCount,ref uadj,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {
                               //writeln("10 Locale=",here.id, " u=",u," and v=",v, " enter forall");
                               var vadj= new set(int,parSafe = true);
                               //var vadj= new set(int);
                               //var vadj=  new DistBag(int,Locales); //use bag to keep the adjacency of v
                               var startv_adj:int;
                               var endv_adj:int;
                               var numv_adj:int;

                               var startvR_adj:int;
                               var endvR_adj:int;
                               var numvR_adj:int;

                               var aggv= newSrcAggregator(int);
                               aggv.copy(startv_adj,sf[v]);
                               aggv.copy(endv_adj,sf[v]+nf[v]-1);
                               aggv.copy(numv_adj,nf[v]);

                               aggv.copy(startvR_adj,sfR[v]);
                               aggv.copy(endvR_adj,sfR[v]+nfR[v]-1);
                               aggv.copy(numvR_adj,nfR[v]);
                               aggv.flush();

                               if (numv_adj>0) {
                                   if (startv_adj>=ld.low && endv_adj<=ld.high) {
                                       forall i in df[startv_adj..endv_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numv_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startv_adj..endv_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+ reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add remote ",i);
                                          }
                                       }

                                   }

                               }
                               if (numvR_adj>0) {
                                   if (startvR_adj>=ldR.low && endvR_adj<=ldR.high) {
                                       forall i in dfR[startvR_adj..endvR_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numvR_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startvR_adj..endvR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                                 agg.copy(a,dfR[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse remote ",i);
                                          }
                                       }

                                   }

                               }
                               //var triset= new set(int,parSafe=true);
                               //var triset= new set(int);
                               //triset=uadj & vadj;
                               //writeln("30 Locale=",here.id, " u=",u, " v=",v, " uadj=",uadj, " vadj=",vadj);
                               //var num=uadj.getSize();
                               var num=vadj.size;
                               var localtricnt=0:int;
                               forall i in vadj with (+ reduce triCount,+reduce localtricnt) {
                                   if uadj.contains(i) {
                                      triCount+=1;
                                      localtricnt+=1;
                                   }
                               }
                               if (localtricnt>0) {
                                   number_edge+=1;
                                   sum_ratio1+=(v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real;
                                   sum_ratio2+=(v_cnt[u]+v_cnt[v]):real/(neighbour[u]+neighbourR[u]+neighbour[v]+neighbourR[v]):real;
                                   //writeln("3333 Locale=",here.id, " tri=", localtricnt," u=",u, " v=",v, " u_cnt=", v_cnt[u], " v_cnt=", v_cnt[v], " ratio=", (v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real);
                               }
                               //writeln("31 Locale=",here.id, "tri=", triCount," u=",u, " v=",v);
                               //vadj.clear();
                           }// end forall v adj build
                           //uadj.clear();
                       }// end forall u adj build
                       subTriSum[here.id]=triCount;
                       RemoteAccessTimes[here.id]=remoteCnt;
                       LocalAccessTimes[here.id]=localCnt;
                       //writeln("100 Locale=",here.id, " subTriSum=", subTriSum);
                   }//end on loc
          }//end coforall loc
          
          var averageratio1:real;
          var averageratio2:real;
          if (number_edge>0) {
              averageratio1=sum_ratio1/number_edge/2:real;
              averageratio2=sum_ratio2/number_edge:real;
          }
          writeln("Average ratio1=", averageratio1, " Total number of edges=",number_edge);
          writeln("Average ratio2=", averageratio2, " Total number of edges=",number_edge);
          var totaltri=0:int;
          for i in subTriSum {
             totaltri+=i;
          }
          //writeln("Estimated triangles 1=",totaltri*Factor*max(1,averageratio1**(0.02)));
          //writeln("Estimated triangles 2=",totaltri*Factor*max(1,averageratio2**(0.1)));
          //writeln("Estimated triangles 3=",totaltri*Factor*max(1,averageratio2**(0.05)));
          //writeln("Estimated triangles 4=",totaltri*Factor*max(1,averageratio2**(0.01)));
          return totaltri;
      }//end of stream_tri_kernel_u



      var sum1=stream_tri_kernel_u(neighbour1, start_i1,src1,dst1,
                           neighbourR1, start_iR1,srcR1,dstR1,StartVerAry1,EndVerAry1,
                           subTriSum1, RemoteAccessTimes1,LocalAccessTimes1,v_cnt1);

      var totalRemote=0:int;
      var totalLocal=0:int;
      for i in RemoteAccessTimes1 {
              totalRemote+=i;
      }
      for i in LocalAccessTimes1 {
              totalLocal+=i;
      }
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("TriangleNumber=", sum1);
      writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
      writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");


      var sum2=stream_tri_kernel_u(neighbour2, start_i2,src2,dst2,
                           neighbourR2, start_iR2,srcR2,dstR2,StartVerAry2,EndVerAry2,
                           subTriSum2, RemoteAccessTimes2,LocalAccessTimes2,v_cnt2);


      totalRemote=0;
      totalLocal=0;
      for i in RemoteAccessTimes2 {
              totalRemote+=i;
      }
      for i in LocalAccessTimes2 {
              totalLocal+=i;
      }
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("TriangleNumber=", sum2);
      writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
      writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");

      var sum3=stream_tri_kernel_u(neighbour3, start_i3,src3,dst3,
                           neighbourR3, start_iR3,srcR3,dstR3,StartVerAry3,EndVerAry3,
                           subTriSum3, RemoteAccessTimes3,LocalAccessTimes3,v_cnt3);


      totalRemote=0;
      totalLocal=0;
      for i in RemoteAccessTimes3 {
              totalRemote+=i;
      }
      for i in LocalAccessTimes3 {
              totalLocal+=i;
      }
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("TriangleNumber=", sum3);
      writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
      writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");

      var tmp:[0..2] int;
      tmp[0]=sum1;
      tmp[1]=sum2;
      tmp[2]=sum3;
      sort(tmp);
      select (CaseS) {
          when "0" {
            TotalCnt[0]=((tmp[0]+tmp[1]+tmp[2])*Factor):int; //average
          }
          when "1" {
            TotalCnt[0]=((-7.835*tmp[0]+6.887*tmp[1]+3.961*tmp[2])*Factor):int; //power law regression
          }
          when "2" {
            TotalCnt[0]=((3.697*tmp[0]-2.236*tmp[1]-1.737*tmp[2])*Factor):int; //normal regression
          } 
          otherwise { 
              var errorMsg = "not implemented case ="+ CaseS;      
              smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);  
              return new MsgTuple(errorMsg, MsgType.ERROR);    
          }

      }

      writeln("Combine three estimates together, triangles=",TotalCnt[0]);
      var countName = st.nextName();
      var countEntry = new shared SymEntry(TotalCnt);
      st.addEntry(countName, countEntry);
      repMsg =  'created ' + st.attrib(countName);

      timer.stop();
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Streaming Triangle Counting time= ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);

  }















// directly read a stream from given file and build the SegGraph class in memory
  proc segStreamHeadTriCntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var (NeS,NvS,ColS,DirectedS, FileName,FactorS) = payload.splitMsgToTuple(6);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var Factor=FactorS:int;
      var StreamNe=Ne/(Factor*3):int;
      var StreamNv=Nv/(Factor*3):int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      if NumCol>2 {
           weighted=1;
      }

      timer.start();
      var src=makeDistArray(StreamNe,int);
      var dst=makeDistArray(StreamNe,int);
      //var length=makeDistArray(StreamNv,int);
      var neighbour=makeDistArray(StreamNv,int);
      var start_i=makeDistArray(StreamNv,int);

      var e_weight = makeDistArray(StreamNe,int);
      var e_cnt = makeDistArray(StreamNe,int);
      var v_weight = makeDistArray(StreamNv,int);
      var v_cnt = makeDistArray(StreamNv,int);

      var iv=makeDistArray(StreamNe,int);

      var srcR=makeDistArray(StreamNe,int);
      var dstR=makeDistArray(StreamNe,int);
      var neighbourR=makeDistArray(StreamNv,int);
      var start_iR=makeDistArray(StreamNv,int);
      ref  ivR=iv;

      var linenum=0:int;

      var repMsg: string;

      var startpos, endpos:int;
      var sort_flag:int;
      var filesize:int;

      var TotalCnt=0:[0..0] int;
      var subTriSum=0: [0..numLocales-1] int;
      var StartVerAry=-1: [0..numLocales-1] int;
      var EndVerAry=-1: [0..numLocales-1] int;
      var RemoteAccessTimes=0: [0..numLocales-1] int;
      var LocalAccessTimes=0: [0..numLocales-1] int;



      proc readLinebyLine() :string throws {
           coforall loc in Locales  {
              on loc {
                  var randv = new RandomStream(real, here.id, false);
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var Streamcurline=0:int;
                  var srclocal=src.localSubdomain();
                  var neilocal=neighbour.localSubdomain();
                  var ewlocal=e_weight.localSubdomain();
                  forall i in srclocal {
                        src[i]=-1;
                        dst[i]=-1;
                        srcR[i]=-1;
                        dstR[i]=-1;
                        e_weight[i]=0;
                        e_cnt[i]=0;
                  }
                  forall i in neilocal {
                        neighbour[i]=0;
                        neighbourR[i]=0;
                        v_weight[i]=0;
                        v_cnt[i]=0;
                        start_i[i]=-1;
                        start_iR[i]=-1;
                  }

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            //if ewlocal.contains(Streamcurline){
                            //    e_weight[Streamcurline]=c:int;
                            //}
                      }
                      var a_hash=(a:int) % StreamNv;
                      var b_hash=(b:int) % StreamNv;
                      if srclocal.contains(Streamcurline) {
                          if ((curline<Ne/3) ) {
                              src[Streamcurline]=a_hash;
                              dst[Streamcurline]=b_hash;
                              e_cnt[Streamcurline]+=1;
                              if neilocal.contains(a_hash) {
                                   v_cnt[a_hash]+=1;
                              }
                              if neilocal.contains(b_hash) {
                                   v_cnt[b_hash]+=1;
                              }
                          }
                      }
                      curline+=1;
                      Streamcurline=curline%StreamNe;
                  } 
                  forall i in src.localSubdomain() {
                       src[i]=src[i]+(src[i]==dst[i]);
                       src[i]=src[i]%StreamNv;
                       dst[i]=dst[i]%StreamNv;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
           return "success";
      }//end readLinebyLine
      
      readLinebyLine();
      //start_i=-1;
      //start_iR=-1;
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      timer.start();

      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  4 { 
                      iv = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32) {    
                      return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             tmpedges=e_cnt[iv];
             e_cnt=tmpedges;

             return "success";
      }//end combine_sort

      proc set_neighbour(){ 
          coforall loc in Locales  {
              on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;
                       var ld=srcf.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       forall i in startEdge..endEdge {
                          var srci=src[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbour[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbour[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newDstAggregator(int);
                              aggd.copy(neighbour[srci],tmpn);
                              aggd.flush();
                          }

                       }

              }
          }
          for i in 0..StreamNe-1 do {
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }

      combine_sort();
      set_neighbour();

      if (directed==0) { //undirected graph

          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  4 { 
                      ivR = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }

             var tmpedges = srcR[ivR]; 
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";

          }// end combine_sortR


          proc set_neighbourR(){ 
              coforall loc in Locales  {
                  on loc {
                       ref srcfR=srcR;
                       ref nfR=neighbourR;
                       ref sfR=start_iR;
                       var ldR=srcfR.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcfR[ldR.low];
                       var endVer=srcfR[ldR.high];

                       var startEdge=ldR.low;
                       var endEdge=ldR.high;

                       forall i in startEdge..endEdge {
                          var srci=srcR[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbourR[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbourR[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newSrcAggregator(int);
                              aggd.copy(neighbourR[srci],tmpn);
                              aggd.flush();
                          }

                       }

                  }//on loc
              }//coforall
              for i in 0..StreamNe-1 do {
                 if (start_iR[srcR[i]] ==-1){
                     start_iR[srcR[i]]=i;
                 }
              }
          }


          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          combine_sortR();
          set_neighbourR();

      }//end of undirected

      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");



      timer.start();

      coforall loc in Locales  {
              on loc {
                  forall i in neighbour.localSubdomain(){
                      if ( v_cnt[i]<=1 ) {
                          neighbour[i]=0;
                          neighbourR[i]=0;
                      }
                  }
              }
      }
      proc stream_tri_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var number_edge=0:int;
          var sum_ratio1=0.0:real;
          var sum_ratio2=0.0:real;
          coforall loc in Locales with (+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2)  {
                   on loc {
                       var triCount=0:int;
                       var remoteCnt=0:int;
                       var localCnt=0:int;
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var ld=srcf.localSubdomain();
                       var ldR=srcfR.localSubdomain();

                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       //writeln("1 Locale=",here.id, " local domain=", ld, ", Reverse local domain=",ldR);

                       if (here.id>0) {
                          if EndVerAry[here.id-1]==StartVerAry[here.id] {
                             startVer+=1;    
                          } else {
                             if (StartVerAry[here.id]-EndVerAry[here.id-1]>2 ){
                                startVer=EndVerAry[here.id-1]+1;
                             }
                          }
                       }
                       if (here.id==numLocales-1) {
                             endVer=nei.size-1;
                       }
                       if (here.id ==0 ) {
                          startVer=0;
                       }

                       //writeln("3 Locale=",here.id, " Updated Starting/End Vertex=[",startVer, ",", endVer, "], StarAry=", StartVerAry, " EndAry=", EndVerAry);
                       forall u in startVer..endVer with (+ reduce triCount,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {// for all the u
                           //writeln("4 Locale=",here.id, " u=",u, " Enter coforall path");
                           var uadj= new set(int,parSafe = true);
                           //var uadj= new set(int);
                           //var uadj=  new DistBag(int,Locales); //use bag to keep the adjacency of u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;

                           var startuR_adj:int;
                           var enduR_adj:int;
                           var numuR_adj:int;

                           var aggu= newSrcAggregator(int);
                           aggu.copy(startu_adj,sf[u]);
                           aggu.copy(endu_adj,sf[u]+nf[u]-1);
                           aggu.copy(numu_adj,nf[u]);

                           aggu.copy(startuR_adj,sfR[u]);
                           aggu.copy(enduR_adj,sfR[u]+nfR[u]-1);
                           aggu.copy(numuR_adj,nfR[u]);
                           aggu.flush();
                           //writeln("6 Locale=",here.id, " u[",startu_adj, ",",endu_adj, "], num=",numu_adj);

                           if (numu_adj>0) {
                               if (startu_adj>=ld.low && endu_adj<=ld.high) {
                                   forall i in df[startu_adj..endu_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add local ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numu_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startu_adj..endu_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add remote ",i);
                                      }
                                   }
                               }
                           }
                           if (numuR_adj>0) {
                               if (startuR_adj>=ldR.low && enduR_adj<=ldR.high) {
                                   forall i in dfR[startuR_adj..enduR_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         // writeln("8 Locale=",here.id,  " u=",u, " add reverse lodal ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numuR_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startuR_adj..enduR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,dfR[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("8 Locale=",here.id,  " u=",u, " add reverse remote ",i);
                                      }
                                   }

                               }

                           }// end of building uadj 
                           //writeln("9 Locale=",here.id, " u=",u," got uadj=",uadj, " numu_adj=", numu_adj," numuR_adj=", numuR_adj);

                           forall v in uadj with (+reduce triCount,ref uadj,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {
                               //writeln("10 Locale=",here.id, " u=",u," and v=",v, " enter forall");
                               var vadj= new set(int,parSafe = true);
                               //var vadj= new set(int);
                               //var vadj=  new DistBag(int,Locales); //use bag to keep the adjacency of v
                               var startv_adj:int;
                               var endv_adj:int;
                               var numv_adj:int;

                               var startvR_adj:int;
                               var endvR_adj:int;
                               var numvR_adj:int;

                               var aggv= newSrcAggregator(int);
                               aggv.copy(startv_adj,sf[v]);
                               aggv.copy(endv_adj,sf[v]+nf[v]-1);
                               aggv.copy(numv_adj,nf[v]);

                               aggv.copy(startvR_adj,sfR[v]);
                               aggv.copy(endvR_adj,sfR[v]+nfR[v]-1);
                               aggv.copy(numvR_adj,nfR[v]);
                               aggv.flush();

                               if (numv_adj>0) {
                                   if (startv_adj>=ld.low && endv_adj<=ld.high) {
                                       forall i in df[startv_adj..endv_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numv_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startv_adj..endv_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+ reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add remote ",i);
                                          }
                                       }

                                   }

                               }
                               if (numvR_adj>0) {
                                   if (startvR_adj>=ldR.low && endvR_adj<=ldR.high) {
                                       forall i in dfR[startvR_adj..endvR_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numvR_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startvR_adj..endvR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                                 agg.copy(a,dfR[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse remote ",i);
                                          }
                                       }

                                   }

                               }
                               //var triset= new set(int,parSafe=true);
                               //var triset= new set(int);
                               //triset=uadj & vadj;
                               //writeln("30 Locale=",here.id, " u=",u, " v=",v, " uadj=",uadj, " vadj=",vadj);
                               //var num=uadj.getSize();
                               var num=vadj.size;
                               var localtricnt=0:int;
                               forall i in vadj with (+ reduce triCount,+reduce localtricnt) {
                                   if uadj.contains(i) {
                                      triCount+=1;
                                      localtricnt+=1;
                                   }
                               }
                               if (localtricnt>0) {
                                   number_edge+=1;
                                   sum_ratio1+=(v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real;
                                   sum_ratio2+=(v_cnt[u]+v_cnt[v]):real/(neighbour[u]+neighbourR[u]+neighbour[v]+neighbourR[v]):real;
                                   //writeln("3333 Locale=",here.id, " tri=", localtricnt," u=",u, " v=",v, " u_cnt=", v_cnt[u], " v_cnt=", v_cnt[v], " ratio=", (v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real);
                               }
                               //writeln("31 Locale=",here.id, "tri=", triCount," u=",u, " v=",v);
                               //vadj.clear();
                           }// end forall v adj build
                           //uadj.clear();
                       }// end forall u adj build
                       subTriSum[here.id]=triCount;
                       RemoteAccessTimes[here.id]=remoteCnt;
                       LocalAccessTimes[here.id]=localCnt;
                       //writeln("100 Locale=",here.id, " subTriSum=", subTriSum);
                   }//end on loc
          }//end coforall loc
          var averageratio1=sum_ratio1/number_edge/2;
          var averageratio2=sum_ratio2/number_edge;
          writeln("Average ratio1=", averageratio1, " Total number of edges=",number_edge);
          writeln("Average ratio2=", averageratio2, " Total number of edges=",number_edge);
          var totaltri=0;
          for i in subTriSum {
             totaltri+=i;
          }
          writeln("Estimated triangles 1=",totaltri*Factor*max(1,averageratio1**(0.02)));
          writeln("Estimated triangles 2=",totaltri*Factor*max(1,averageratio2**(0.1)));
          writeln("Estimated triangles 3=",totaltri*Factor*max(1,averageratio2**(0.05)));
          writeln("Estimated triangles 4=",totaltri*Factor*max(1,averageratio2**(0.01)));
          return "success";
      }//end of stream_tri_kernel_u


      proc return_stream_tri_count(): string throws{
          for i in subTriSum {
             TotalCnt[0]+=i;
          }
          var totalRemote=0:int;
          var totalLocal=0:int;
          for i in RemoteAccessTimes {
              totalRemote+=i;
          }
          for i in LocalAccessTimes {
              totalLocal+=i;
          }
          //TotalCnt[0]/=3;
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("TriangleNumber=", TotalCnt[0]);
          writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
          writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          //writeln("1000 Locale=",here.id, " subTriSum=", subTriSum, "TotalCnt=",TotalCnt);
          var countName = st.nextName();
          var countEntry = new shared SymEntry(TotalCnt);
          st.addEntry(countName, countEntry);

          var cntMsg =  'created ' + st.attrib(countName);
          return cntMsg;

      }//end of proc return_stream


      stream_tri_kernel_u(neighbour, start_i,src,dst,
                           neighbourR, start_iR,srcR,dstR);
      repMsg=return_stream_tri_count();
      
      timer.stop();
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Streaming Triangle Counting time= ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);

  }





// directly read a stream from given file and build the SegGraph class in memory
  proc segStreamTailTriCntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var (NeS,NvS,ColS,DirectedS, FileName,FactorS) = payload.splitMsgToTuple(6);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var Factor=FactorS:int;
      var StreamNe=Ne/(Factor*3):int;
      var StreamNv=Nv/(Factor*3):int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      if NumCol>2 {
           weighted=1;
      }

      timer.start();
      var src=makeDistArray(StreamNe,int);
      var dst=makeDistArray(StreamNe,int);
      //var length=makeDistArray(StreamNv,int);
      var neighbour=makeDistArray(StreamNv,int);
      var start_i=makeDistArray(StreamNv,int);

      var e_weight = makeDistArray(StreamNe,int);
      var e_cnt = makeDistArray(StreamNe,int);
      var v_weight = makeDistArray(StreamNv,int);
      var v_cnt = makeDistArray(StreamNv,int);

      var iv=makeDistArray(StreamNe,int);

      var srcR=makeDistArray(StreamNe,int);
      var dstR=makeDistArray(StreamNe,int);
      var neighbourR=makeDistArray(StreamNv,int);
      var start_iR=makeDistArray(StreamNv,int);
      ref  ivR=iv;

      var linenum=0:int;

      var repMsg: string;

      var startpos, endpos:int;
      var sort_flag:int;
      var filesize:int;

      var TotalCnt=0:[0..0] int;
      var subTriSum=0: [0..numLocales-1] int;
      var StartVerAry=-1: [0..numLocales-1] int;
      var EndVerAry=-1: [0..numLocales-1] int;
      var RemoteAccessTimes=0: [0..numLocales-1] int;
      var LocalAccessTimes=0: [0..numLocales-1] int;



      proc readLinebyLine() throws {
           coforall loc in Locales  {
              on loc {
                  var randv = new RandomStream(real, here.id, false);
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var Streamcurline=0:int;
                  var srclocal=src.localSubdomain();
                  var neilocal=neighbour.localSubdomain();
                  var ewlocal=e_weight.localSubdomain();
                  forall i in srclocal {
                        src[i]=-1;
                        dst[i]=-1;
                        srcR[i]=-1;
                        dstR[i]=-1;
                        e_weight[i]=0;
                        e_cnt[i]=0;
                  }
                  forall i in neilocal {
                        neighbour[i]=0;
                        neighbourR[i]=0;
                        v_weight[i]=0;
                        v_cnt[i]=0;
                        start_i[i]=-1;
                        start_iR[i]=-1;
                  }

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            //if ewlocal.contains(Streamcurline){
                            //    e_weight[Streamcurline]=c:int;
                            //}
                      }
                      var a_hash=(a:int) % StreamNv;
                      var b_hash=(b:int) % StreamNv;
                      if srclocal.contains(Streamcurline) {
                          if ((curline>=Ne*2/3) ) {
                              src[Streamcurline]=a_hash;
                              dst[Streamcurline]=b_hash;
                              e_cnt[Streamcurline]+=1;
                              if neilocal.contains(a_hash) {
                                   v_cnt[a_hash]+=1;
                              }
                              if neilocal.contains(b_hash) {
                                   v_cnt[b_hash]+=1;
                              }
                          }
                      }
                      curline+=1;
                      Streamcurline=curline%StreamNe;
                  } 
                  forall i in src.localSubdomain() {
                       src[i]=src[i]+(src[i]==dst[i]);
                       src[i]=src[i]%StreamNv;
                       dst[i]=dst[i]%StreamNv;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
      }//end readLinebyLine
      
      readLinebyLine();
      //start_i=-1;
      //start_iR=-1;
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      timer.start();

      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  4 { 
                      iv = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32) {    
                      return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             tmpedges=e_cnt[iv];
             e_cnt=tmpedges;

             return "success";
      }//end combine_sort

      proc set_neighbour(){ 
          coforall loc in Locales  {
              on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;
                       var ld=srcf.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       forall i in startEdge..endEdge {
                          var srci=src[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbour[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbour[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newDstAggregator(int);
                              aggd.copy(neighbour[srci],tmpn);
                              aggd.flush();
                          }

                       }

              }
          }
          for i in 0..StreamNe-1 do {
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }

      combine_sort();
      set_neighbour();

      if (directed==0) { //undirected graph

          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  4 { 
                      ivR = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }

             var tmpedges = srcR[ivR]; 
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";

          }// end combine_sortR


          proc set_neighbourR(){ 
              coforall loc in Locales  {
                  on loc {
                       ref srcfR=srcR;
                       ref nfR=neighbourR;
                       ref sfR=start_iR;
                       var ldR=srcfR.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcfR[ldR.low];
                       var endVer=srcfR[ldR.high];

                       var startEdge=ldR.low;
                       var endEdge=ldR.high;

                       forall i in startEdge..endEdge {
                          var srci=srcR[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbourR[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbourR[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newSrcAggregator(int);
                              aggd.copy(neighbourR[srci],tmpn);
                              aggd.flush();
                          }

                       }

                  }//on loc
              }//coforall
              for i in 0..StreamNe-1 do {
                 if (start_iR[srcR[i]] ==-1){
                     start_iR[srcR[i]]=i;
                 }
              }
          }


          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          combine_sortR();
          set_neighbourR();

      }//end of undirected

      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");



      timer.start();

      coforall loc in Locales  {
              on loc {
                  forall i in neighbour.localSubdomain(){
                      if ( v_cnt[i]<=1 ) {
                          neighbour[i]=0;
                          neighbourR[i]=0;
                      }
                  }
              }
      }
      proc stream_tri_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var number_edge=0:int;
          var sum_ratio1=0.0:real;
          var sum_ratio2=0.0:real;
          coforall loc in Locales with (+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2)  {
                   on loc {
                       var triCount=0:int;
                       var remoteCnt=0:int;
                       var localCnt=0:int;
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var ld=srcf.localSubdomain();
                       var ldR=srcfR.localSubdomain();

                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       //writeln("1 Locale=",here.id, " local domain=", ld, ", Reverse local domain=",ldR);

                       if (here.id>0) {
                          if EndVerAry[here.id-1]==StartVerAry[here.id] {
                             startVer+=1;    
                          } else {
                             if (StartVerAry[here.id]-EndVerAry[here.id-1]>2 ){
                                startVer=EndVerAry[here.id-1]+1;
                             }
                          }
                       }
                       if (here.id==numLocales-1) {
                             endVer=nei.size-1;
                       }
                       if (here.id ==0 ) {
                          startVer=0;
                       }

                       //writeln("3 Locale=",here.id, " Updated Starting/End Vertex=[",startVer, ",", endVer, "], StarAry=", StartVerAry, " EndAry=", EndVerAry);
                       forall u in startVer..endVer with (+ reduce triCount,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {// for all the u
                           //writeln("4 Locale=",here.id, " u=",u, " Enter coforall path");
                           var uadj= new set(int,parSafe = true);
                           //var uadj= new set(int);
                           //var uadj=  new DistBag(int,Locales); //use bag to keep the adjacency of u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;

                           var startuR_adj:int;
                           var enduR_adj:int;
                           var numuR_adj:int;

                           var aggu= newSrcAggregator(int);
                           aggu.copy(startu_adj,sf[u]);
                           aggu.copy(endu_adj,sf[u]+nf[u]-1);
                           aggu.copy(numu_adj,nf[u]);

                           aggu.copy(startuR_adj,sfR[u]);
                           aggu.copy(enduR_adj,sfR[u]+nfR[u]-1);
                           aggu.copy(numuR_adj,nfR[u]);
                           aggu.flush();
                           //writeln("6 Locale=",here.id, " u[",startu_adj, ",",endu_adj, "], num=",numu_adj);

                           if (numu_adj>0) {
                               if (startu_adj>=ld.low && endu_adj<=ld.high) {
                                   forall i in df[startu_adj..endu_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add local ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numu_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startu_adj..endu_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add remote ",i);
                                      }
                                   }
                               }
                           }
                           if (numuR_adj>0) {
                               if (startuR_adj>=ldR.low && enduR_adj<=ldR.high) {
                                   forall i in dfR[startuR_adj..enduR_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         // writeln("8 Locale=",here.id,  " u=",u, " add reverse lodal ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numuR_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startuR_adj..enduR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,dfR[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("8 Locale=",here.id,  " u=",u, " add reverse remote ",i);
                                      }
                                   }

                               }

                           }// end of building uadj 
                           //writeln("9 Locale=",here.id, " u=",u," got uadj=",uadj, " numu_adj=", numu_adj," numuR_adj=", numuR_adj);

                           forall v in uadj with (+reduce triCount,ref uadj,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {
                               //writeln("10 Locale=",here.id, " u=",u," and v=",v, " enter forall");
                               var vadj= new set(int,parSafe = true);
                               //var vadj= new set(int);
                               //var vadj=  new DistBag(int,Locales); //use bag to keep the adjacency of v
                               var startv_adj:int;
                               var endv_adj:int;
                               var numv_adj:int;

                               var startvR_adj:int;
                               var endvR_adj:int;
                               var numvR_adj:int;

                               var aggv= newSrcAggregator(int);
                               aggv.copy(startv_adj,sf[v]);
                               aggv.copy(endv_adj,sf[v]+nf[v]-1);
                               aggv.copy(numv_adj,nf[v]);

                               aggv.copy(startvR_adj,sfR[v]);
                               aggv.copy(endvR_adj,sfR[v]+nfR[v]-1);
                               aggv.copy(numvR_adj,nfR[v]);
                               aggv.flush();

                               if (numv_adj>0) {
                                   if (startv_adj>=ld.low && endv_adj<=ld.high) {
                                       forall i in df[startv_adj..endv_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numv_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startv_adj..endv_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+ reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add remote ",i);
                                          }
                                       }

                                   }

                               }
                               if (numvR_adj>0) {
                                   if (startvR_adj>=ldR.low && endvR_adj<=ldR.high) {
                                       forall i in dfR[startvR_adj..endvR_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numvR_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startvR_adj..endvR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                                 agg.copy(a,dfR[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse remote ",i);
                                          }
                                       }

                                   }

                               }
                               //var triset= new set(int,parSafe=true);
                               //var triset= new set(int);
                               //triset=uadj & vadj;
                               //writeln("30 Locale=",here.id, " u=",u, " v=",v, " uadj=",uadj, " vadj=",vadj);
                               //var num=uadj.getSize();
                               var num=vadj.size;
                               var localtricnt=0:int;
                               forall i in vadj with (+ reduce triCount,+reduce localtricnt) {
                                   if uadj.contains(i) {
                                      triCount+=1;
                                      localtricnt+=1;
                                   }
                               }
                               if (localtricnt>0) {
                                   number_edge+=1;
                                   sum_ratio1+=(v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real;
                                   sum_ratio2+=(v_cnt[u]+v_cnt[v]):real/(neighbour[u]+neighbourR[u]+neighbour[v]+neighbourR[v]):real;
                                   //writeln("3333 Locale=",here.id, " tri=", localtricnt," u=",u, " v=",v, " u_cnt=", v_cnt[u], " v_cnt=", v_cnt[v], " ratio=", (v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real);
                               }
                               //writeln("31 Locale=",here.id, "tri=", triCount," u=",u, " v=",v);
                               //vadj.clear();
                           }// end forall v adj build
                           //uadj.clear();
                       }// end forall u adj build
                       subTriSum[here.id]=triCount;
                       RemoteAccessTimes[here.id]=remoteCnt;
                       LocalAccessTimes[here.id]=localCnt;
                       //writeln("100 Locale=",here.id, " subTriSum=", subTriSum);
                   }//end on loc
          }//end coforall loc
          var averageratio1=sum_ratio1/number_edge/2;
          var averageratio2=sum_ratio2/number_edge;
          writeln("Average ratio1=", averageratio1, " Total number of edges=",number_edge);
          writeln("Average ratio2=", averageratio2, " Total number of edges=",number_edge);
          var totaltri=0;
          for i in subTriSum {
             totaltri+=i;
          }
          writeln("Estimated triangles 1=",totaltri*Factor*max(1,averageratio1**(0.02)));
          writeln("Estimated triangles 2=",totaltri*Factor*max(1,averageratio2**(0.1)));
          writeln("Estimated triangles 3=",totaltri*Factor*max(1,averageratio2**(0.05)));
          writeln("Estimated triangles 4=",totaltri*Factor*max(1,averageratio2**(0.01)));
          return "success";
      }//end of stream_tri_kernel_u


      proc return_stream_tri_count(): string throws{
          for i in subTriSum {
             TotalCnt[0]+=i;
          }
          var totalRemote=0:int;
          var totalLocal=0:int;
          for i in RemoteAccessTimes {
              totalRemote+=i;
          }
          for i in LocalAccessTimes {
              totalLocal+=i;
          }
          //TotalCnt[0]/=3;
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("TriangleNumber=", TotalCnt[0]);
          writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
          writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          //writeln("1000 Locale=",here.id, " subTriSum=", subTriSum, "TotalCnt=",TotalCnt);
          var countName = st.nextName();
          var countEntry = new shared SymEntry(TotalCnt);
          st.addEntry(countName, countEntry);

          var cntMsg =  'created ' + st.attrib(countName);
          return cntMsg;

      }//end of proc return_stream


      stream_tri_kernel_u(neighbour, start_i,src,dst,
                           neighbourR, start_iR,srcR,dstR);
      repMsg=return_stream_tri_count();
      
      timer.stop();
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Streaming Triangle Counting time= ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);

  }






// directly read a stream from given file and build the SegGraph class in memory
  proc segStreamMidTriCntMsg(cmd: string, payload: string, st: borrowed SymTab): MsgTuple throws {
      var (NeS,NvS,ColS,DirectedS, FileName,FactorS) = payload.splitMsgToTuple(6);
      //writeln("======================Graph Reading=====================");
      //writeln(NeS,NvS,ColS,DirectedS, FileName);
      var Ne=NeS:int;
      var Nv=NvS:int;
      var Factor=FactorS:int;
      var StreamNe=Ne/(Factor*3):int;
      var StreamNv=Nv/(Factor*3):int;
      var NumCol=ColS:int;
      var directed=DirectedS:int;
      var weighted=0:int;
      var timer: Timer;
      if NumCol>2 {
           weighted=1;
      }

      timer.start();
      var src=makeDistArray(StreamNe,int);
      var dst=makeDistArray(StreamNe,int);
      //var length=makeDistArray(StreamNv,int);
      var neighbour=makeDistArray(StreamNv,int);
      var start_i=makeDistArray(StreamNv,int);

      var e_weight = makeDistArray(StreamNe,int);
      var e_cnt = makeDistArray(StreamNe,int);
      var v_weight = makeDistArray(StreamNv,int);
      var v_cnt = makeDistArray(StreamNv,int);

      var iv=makeDistArray(StreamNe,int);

      var srcR=makeDistArray(StreamNe,int);
      var dstR=makeDistArray(StreamNe,int);
      var neighbourR=makeDistArray(StreamNv,int);
      var start_iR=makeDistArray(StreamNv,int);
      ref  ivR=iv;

      var linenum=0:int;

      var repMsg: string;

      var startpos, endpos:int;
      var sort_flag:int;
      var filesize:int;

      var TotalCnt=0:[0..0] int;
      var subTriSum=0: [0..numLocales-1] int;
      var StartVerAry=-1: [0..numLocales-1] int;
      var EndVerAry=-1: [0..numLocales-1] int;
      var RemoteAccessTimes=0: [0..numLocales-1] int;
      var LocalAccessTimes=0: [0..numLocales-1] int;



      proc readLinebyLine() throws {
           coforall loc in Locales  {
              on loc {
                  var randv = new RandomStream(real, here.id, false);
                  var f = open(FileName, iomode.r);
                  var r = f.reader(kind=ionative);
                  var line:string;
                  var a,b,c:string;
                  var curline=0:int;
                  var Streamcurline=0:int;
                  var srclocal=src.localSubdomain();
                  var neilocal=neighbour.localSubdomain();
                  var ewlocal=e_weight.localSubdomain();
                  forall i in srclocal {
                        src[i]=-1;
                        dst[i]=-1;
                        srcR[i]=-1;
                        dstR[i]=-1;
                        e_weight[i]=0;
                        e_cnt[i]=0;
                  }
                  forall i in neilocal {
                        neighbour[i]=0;
                        neighbourR[i]=0;
                        v_weight[i]=0;
                        v_cnt[i]=0;
                        start_i[i]=-1;
                        start_iR[i]=-1;
                  }

                  while r.readline(line) {
                      if NumCol==2 {
                           (a,b)=  line.splitMsgToTuple(2);
                      } else {
                           (a,b,c)=  line.splitMsgToTuple(3);
                            //if ewlocal.contains(Streamcurline){
                            //    e_weight[Streamcurline]=c:int;
                            //}
                      }
                      var a_hash=(a:int) % StreamNv;
                      var b_hash=(b:int) % StreamNv;
                      if srclocal.contains(Streamcurline) {
                          if ((curline<2*Ne/3) && (curline>=Ne/3) ) {
                              src[Streamcurline]=a_hash;
                              dst[Streamcurline]=b_hash;
                              e_cnt[Streamcurline]+=1;
                              if neilocal.contains(a_hash) {
                                   v_cnt[a_hash]+=1;
                              }
                              if neilocal.contains(b_hash) {
                                   v_cnt[b_hash]+=1;
                              }
                          }
                      }
                      curline+=1;
                      Streamcurline=curline%StreamNe;
                  } 
                  forall i in src.localSubdomain() {
                       src[i]=src[i]+(src[i]==dst[i]);
                       src[i]=src[i]%StreamNv;
                       dst[i]=dst[i]%StreamNv;
                  }
                  r.close();
                  f.close();
               }// end on loc
           }//end coforall
      }//end readLinebyLine
      
      readLinebyLine();
      //start_i=-1;
      //start_iR=-1;
      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Reading File takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      timer.start();

      proc combine_sort() throws {
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [src,dst], negs) {
                       (bitWidth, neg) = getBitWidth(ary); 
                       totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;
             }
             proc mergedArgsort(param numDigits) throws {
                    //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
                    //             + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
                    var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
                    var curDigit = numDigits - totalDigits;
                    for (ary , nBits, neg) in zip([src,dst], bitWidths, negs) {
                        proc mergeArray(type t) {
                            ref A = ary;
                            const r = 0..#nBits by bitsPerDigit;
                            for rshift in r {
                                 const myDigit = (r.high - rshift) / bitsPerDigit;
                                 const last = myDigit == 0;
                                 forall (m, a) in zip(merged, A) {
                                     m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                                 }
                            }
                            curDigit += r.size;
                        }
                        mergeArray(int); 
                    }
                    var tmpiv = argsortDefault(merged);
                    return tmpiv;
             }

             try {
                 if totalDigits <=  4 { 
                      iv = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      iv =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      iv = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      iv = mergedArgsort(32); 
                 }
                 if (totalDigits >32) {    
                      return "Error, TotalDigits >32";
                 }

             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }
             var tmpedges=src[iv];
             src=tmpedges;
             tmpedges=dst[iv];
             dst=tmpedges;
             tmpedges=e_cnt[iv];
             e_cnt=tmpedges;

             return "success";
      }//end combine_sort

      proc set_neighbour(){ 
          coforall loc in Locales  {
              on loc {
                       ref srcf=src;
                       ref df=dst;
                       ref nf=neighbour;
                       ref sf=start_i;
                       var ld=srcf.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       forall i in startEdge..endEdge {
                          var srci=src[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbour[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbour[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newDstAggregator(int);
                              aggd.copy(neighbour[srci],tmpn);
                              aggd.flush();
                          }

                       }

              }
          }
          for i in 0..StreamNe-1 do {
             if (start_i[src[i]] ==-1){
                 start_i[src[i]]=i;
             }
          }
      }

      combine_sort();
      set_neighbour();

      if (directed==0) { //undirected graph

          proc combine_sortR() throws {
             /* we cannot use the coargsort version because it will break the memory limit */
             param bitsPerDigit = RSLSD_bitsPerDigit;
             var bitWidths: [0..1] int;
             var negs: [0..1] bool;
             var totalDigits: int;
             var size=StreamNe: int;
             for (bitWidth, ary, neg) in zip(bitWidths, [srcR,dstR], negs) {
                 (bitWidth, neg) = getBitWidth(ary); 
                 totalDigits += (bitWidth + (bitsPerDigit-1)) / bitsPerDigit;

             }
             proc mergedArgsort(param numDigits) throws {
               //overMemLimit(((4 + 3) * size * (numDigits * bitsPerDigit / 8))
               //          + (2 * here.maxTaskPar * numLocales * 2**16 * 8));
               var merged = makeDistArray(size, numDigits*uint(bitsPerDigit));
               var curDigit = numDigits - totalDigits;
               for (ary , nBits, neg) in zip([srcR,dstR], bitWidths, negs) {
                  proc mergeArray(type t) {
                     ref A = ary;
                     const r = 0..#nBits by bitsPerDigit;
                     for rshift in r {
                        const myDigit = (r.high - rshift) / bitsPerDigit;
                        const last = myDigit == 0;
                        forall (m, a) in zip(merged, A) {
                             m[curDigit+myDigit] =  getDigit(a, rshift, last, neg):uint(bitsPerDigit);
                        }
                     }
                     curDigit += r.size;
                  }
                  mergeArray(int); 
               }
               var tmpiv = argsortDefault(merged);
               return tmpiv;
             } 

             try {
                 if totalDigits <=  4 { 
                      ivR = mergedArgsort( 4); 
                 }
                 if (totalDigits >  4) && ( totalDigits <=  8) { 
                      ivR =  mergedArgsort( 8); 
                 }
                 if (totalDigits >  8) && ( totalDigits <=  16) { 
                      ivR = mergedArgsort(16); 
                 }
                 if (totalDigits >  16) && ( totalDigits <=  32) { 
                      ivR = mergedArgsort(32); 
                 }
             } catch e: Error {
                  smLogger.error(getModuleName(),getRoutineName(),getLineNumber(),
                      e.message());
                    return "Error: %t".format(e.message());
             }

             var tmpedges = srcR[ivR]; 
             srcR=tmpedges;
             tmpedges = dstR[ivR]; 
             dstR=tmpedges;
             return "success";

          }// end combine_sortR


          proc set_neighbourR(){ 
              coforall loc in Locales  {
                  on loc {
                       ref srcfR=srcR;
                       ref nfR=neighbourR;
                       ref sfR=start_iR;
                       var ldR=srcfR.localSubdomain();
                       // first we divide vertices based on the number of edges
                       var startVer=srcfR[ldR.low];
                       var endVer=srcfR[ldR.high];

                       var startEdge=ldR.low;
                       var endEdge=ldR.high;

                       forall i in startEdge..endEdge {
                          var srci=srcR[i];
                          if ((srci>=startVer) && (srci<=endVer)) {
                              neighbourR[srci]+=1;
                             
                          } else {
                              var tmpn:int;
                              var tmpstart:int;
                              var aggs= newSrcAggregator(int);
                              aggs.copy(tmpn,neighbourR[srci]);
                              aggs.flush();
                              tmpn+=1;
                              var aggd= newSrcAggregator(int);
                              aggd.copy(neighbourR[srci],tmpn);
                              aggd.flush();
                          }

                       }

                  }//on loc
              }//coforall
              for i in 0..StreamNe-1 do {
                 if (start_iR[srcR[i]] ==-1){
                     start_iR[srcR[i]]=i;
                 }
              }
          }


          coforall loc in Locales  {
              on loc {
                  forall i in srcR.localSubdomain(){
                        srcR[i]=dst[i];
                        dstR[i]=src[i];
                   }
              }
          }
          combine_sortR();
          set_neighbourR();

      }//end of undirected

      timer.stop();
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$Sorting Edges takes ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$  $$$$$$$$$$$$$$$$$$$$$$$");



      timer.start();

      coforall loc in Locales  {
              on loc {
                  forall i in neighbour.localSubdomain(){
                      if ( v_cnt[i]<=1 ) {
                          neighbour[i]=0;
                          neighbourR[i]=0;
                      }
                  }
              }
      }
      proc stream_tri_kernel_u(nei:[?D1] int, start_i:[?D2] int,src:[?D3] int, dst:[?D4] int,
                        neiR:[?D11] int, start_iR:[?D12] int,srcR:[?D13] int, dstR:[?D14] int):string throws{
          var number_edge=0:int;
          var sum_ratio1=0.0:real;
          var sum_ratio2=0.0:real;
          coforall loc in Locales with (+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2)  {
                   on loc {
                       var triCount=0:int;
                       var remoteCnt=0:int;
                       var localCnt=0:int;
                       ref srcf=src;
                       ref df=dst;
                       ref nf=nei;
                       ref sf=start_i;

                       ref srcfR=srcR;
                       ref dfR=dstR;
                       ref nfR=neiR;
                       ref sfR=start_iR;

                       var ld=srcf.localSubdomain();
                       var ldR=srcfR.localSubdomain();

                       // first we divide vertices based on the number of edges
                       var startVer=srcf[ld.low];
                       var endVer=srcf[ld.high];

                       StartVerAry[here.id]=startVer;
                       EndVerAry[here.id]=endVer;
                       var startEdge=ld.low;
                       var endEdge=ld.high;

                       var lastVer=-1;

                       //writeln("1 Locale=",here.id, " local domain=", ld, ", Reverse local domain=",ldR);

                       if (here.id>0) {
                          if EndVerAry[here.id-1]==StartVerAry[here.id] {
                             startVer+=1;    
                          } else {
                             if (StartVerAry[here.id]-EndVerAry[here.id-1]>2 ){
                                startVer=EndVerAry[here.id-1]+1;
                             }
                          }
                       }
                       if (here.id==numLocales-1) {
                             endVer=nei.size-1;
                       }
                       if (here.id ==0 ) {
                          startVer=0;
                       }

                       //writeln("3 Locale=",here.id, " Updated Starting/End Vertex=[",startVer, ",", endVer, "], StarAry=", StartVerAry, " EndAry=", EndVerAry);
                       forall u in startVer..endVer with (+ reduce triCount,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {// for all the u
                           //writeln("4 Locale=",here.id, " u=",u, " Enter coforall path");
                           var uadj= new set(int,parSafe = true);
                           //var uadj= new set(int);
                           //var uadj=  new DistBag(int,Locales); //use bag to keep the adjacency of u
                           var startu_adj:int;
                           var endu_adj:int;
                           var numu_adj:int;

                           var startuR_adj:int;
                           var enduR_adj:int;
                           var numuR_adj:int;

                           var aggu= newSrcAggregator(int);
                           aggu.copy(startu_adj,sf[u]);
                           aggu.copy(endu_adj,sf[u]+nf[u]-1);
                           aggu.copy(numu_adj,nf[u]);

                           aggu.copy(startuR_adj,sfR[u]);
                           aggu.copy(enduR_adj,sfR[u]+nfR[u]-1);
                           aggu.copy(numuR_adj,nfR[u]);
                           aggu.flush();
                           //writeln("6 Locale=",here.id, " u[",startu_adj, ",",endu_adj, "], num=",numu_adj);

                           if (numu_adj>0) {
                               if (startu_adj>=ld.low && endu_adj<=ld.high) {
                                   forall i in df[startu_adj..endu_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add local ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numu_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startu_adj..endu_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("7 Locale=",here.id,  " u=",u, " add remote ",i);
                                      }
                                   }
                               }
                           }
                           if (numuR_adj>0) {
                               if (startuR_adj>=ldR.low && enduR_adj<=ldR.high) {
                                   forall i in dfR[startuR_adj..enduR_adj] with (ref uadj,+ reduce localCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         localCnt+=1;
                                         // writeln("8 Locale=",here.id,  " u=",u, " add reverse lodal ",i);
                                      }
                                   }
                               } else {
                                   var tmpuadj: [0..numuR_adj-1]int;
                                   forall (a,b) in zip(tmpuadj,(startuR_adj..enduR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,dfR[b]);
                                   }
                                   forall i in tmpuadj with (ref uadj,+ reduce remoteCnt) {
                                      if (u<i) {
                                         uadj.add(i);
                                         remoteCnt+=1;
                                         //writeln("8 Locale=",here.id,  " u=",u, " add reverse remote ",i);
                                      }
                                   }

                               }

                           }// end of building uadj 
                           //writeln("9 Locale=",here.id, " u=",u," got uadj=",uadj, " numu_adj=", numu_adj," numuR_adj=", numuR_adj);

                           forall v in uadj with (+reduce triCount,ref uadj,+ reduce remoteCnt, + reduce localCnt,+ reduce number_edge, + reduce sum_ratio1,+reduce sum_ratio2) {
                               //writeln("10 Locale=",here.id, " u=",u," and v=",v, " enter forall");
                               var vadj= new set(int,parSafe = true);
                               //var vadj= new set(int);
                               //var vadj=  new DistBag(int,Locales); //use bag to keep the adjacency of v
                               var startv_adj:int;
                               var endv_adj:int;
                               var numv_adj:int;

                               var startvR_adj:int;
                               var endvR_adj:int;
                               var numvR_adj:int;

                               var aggv= newSrcAggregator(int);
                               aggv.copy(startv_adj,sf[v]);
                               aggv.copy(endv_adj,sf[v]+nf[v]-1);
                               aggv.copy(numv_adj,nf[v]);

                               aggv.copy(startvR_adj,sfR[v]);
                               aggv.copy(endvR_adj,sfR[v]+nfR[v]-1);
                               aggv.copy(numvR_adj,nfR[v]);
                               aggv.flush();

                               if (numv_adj>0) {
                                   if (startv_adj>=ld.low && endv_adj<=ld.high) {
                                       forall i in df[startv_adj..endv_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numv_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startv_adj..endv_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                             agg.copy(a,df[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+ reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("11 Locale=",here.id,  " v=",v, " add remote ",i);
                                          }
                                       }

                                   }

                               }
                               if (numvR_adj>0) {
                                   if (startvR_adj>=ldR.low && endvR_adj<=ldR.high) {
                                       forall i in dfR[startvR_adj..endvR_adj] with (ref vadj,+ reduce localCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             localCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse local ",i);
                                          }
                                       }
                                   } else {
                                       var tmpvadj: [0..numvR_adj-1]int;
                                       forall (a,b) in zip(tmpvadj,(startvR_adj..endvR_adj)) 
                                             with (var agg= newSrcAggregator(int)) {
                                                 agg.copy(a,dfR[b]);
                                       }
                                       forall i in tmpvadj with (ref vadj,+reduce remoteCnt) {
                                          if (v<i) {
                                             vadj.add(i);
                                             remoteCnt+=1;
                                             //writeln("12 Locale=",here.id,  " v=",v, " add reverse remote ",i);
                                          }
                                       }

                                   }

                               }
                               //var triset= new set(int,parSafe=true);
                               //var triset= new set(int);
                               //triset=uadj & vadj;
                               //writeln("30 Locale=",here.id, " u=",u, " v=",v, " uadj=",uadj, " vadj=",vadj);
                               //var num=uadj.getSize();
                               var num=vadj.size;
                               var localtricnt=0:int;
                               forall i in vadj with (+ reduce triCount,+reduce localtricnt) {
                                   if uadj.contains(i) {
                                      triCount+=1;
                                      localtricnt+=1;
                                   }
                               }
                               if (localtricnt>0) {
                                   number_edge+=1;
                                   sum_ratio1+=(v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real;
                                   sum_ratio2+=(v_cnt[u]+v_cnt[v]):real/(neighbour[u]+neighbourR[u]+neighbour[v]+neighbourR[v]):real;
                                   //writeln("3333 Locale=",here.id, " tri=", localtricnt," u=",u, " v=",v, " u_cnt=", v_cnt[u], " v_cnt=", v_cnt[v], " ratio=", (v_cnt[u]-neighbour[u]-neighbourR[u]+v_cnt[v]-neighbour[v]-neighbourR[v])/localtricnt:real);
                               }
                               //writeln("31 Locale=",here.id, "tri=", triCount," u=",u, " v=",v);
                               //vadj.clear();
                           }// end forall v adj build
                           //uadj.clear();
                       }// end forall u adj build
                       subTriSum[here.id]=triCount;
                       RemoteAccessTimes[here.id]=remoteCnt;
                       LocalAccessTimes[here.id]=localCnt;
                       //writeln("100 Locale=",here.id, " subTriSum=", subTriSum);
                   }//end on loc
          }//end coforall loc
          var averageratio1=sum_ratio1/number_edge/2;
          var averageratio2=sum_ratio2/number_edge;
          writeln("Average ratio1=", averageratio1, " Total number of edges=",number_edge);
          writeln("Average ratio2=", averageratio2, " Total number of edges=",number_edge);
          var totaltri=0;
          for i in subTriSum {
             totaltri+=i;
          }
          writeln("Estimated triangles 1=",totaltri*Factor*max(1,averageratio1**(0.02)));
          writeln("Estimated triangles 2=",totaltri*Factor*max(1,averageratio2**(0.1)));
          writeln("Estimated triangles 3=",totaltri*Factor*max(1,averageratio2**(0.05)));
          writeln("Estimated triangles 4=",totaltri*Factor*max(1,averageratio2**(0.01)));
          return "success";
      }//end of stream_tri_kernel_u


      proc return_stream_tri_count(): string throws{
          for i in subTriSum {
             TotalCnt[0]+=i;
          }
          var totalRemote=0:int;
          var totalLocal=0:int;
          for i in RemoteAccessTimes {
              totalRemote+=i;
          }
          for i in LocalAccessTimes {
              totalLocal+=i;
          }
          //TotalCnt[0]/=3;
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          writeln("TriangleNumber=", TotalCnt[0]);
          writeln("LocalRatio=", (totalLocal:real)/((totalRemote+totalLocal):real),", TotalTimes=",totalRemote+totalLocal);
          writeln("LocalAccessTimes=", totalLocal,", RemoteAccessTimes=",totalRemote);
          writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
          //writeln("1000 Locale=",here.id, " subTriSum=", subTriSum, "TotalCnt=",TotalCnt);
          var countName = st.nextName();
          var countEntry = new shared SymEntry(TotalCnt);
          st.addEntry(countName, countEntry);

          var cntMsg =  'created ' + st.attrib(countName);
          return cntMsg;

      }//end of proc return_stream


      stream_tri_kernel_u(neighbour, start_i,src,dst,
                           neighbourR, start_iR,srcR,dstR);
      repMsg=return_stream_tri_count();
      
      timer.stop();
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$ Streaming Triangle Counting time= ", timer.elapsed()," $$$$$$$$$$$$$$$$$$$$$$$");
      writeln("$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$");
      smLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
      return new MsgTuple(repMsg, MsgType.NORMAL);

  }















}


