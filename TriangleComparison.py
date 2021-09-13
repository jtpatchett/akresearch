#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Sat Jul 24 17:06:43 2021

@author: joseph
"""

import arkouda as ak
import sys

def run_test(ak_server, graph_location, num_edges, num_vertices, num_cols, directed):
    ak.connect(connect_url=ak_server)
    graph = ak.graph_file_read(num_edges,num_vertices,num_cols, directed, graph_location)
#testval2 = ak.pdarraycreation.graph_triangle(graph)
    testval2 = ak.pdarraycreation.graph_triangle_edge(graph)
    return testval2;

if __name__ == '__main__':
    print(sys.argv)
    ak_server = str(sys.argv[1])
    graph_loc = str(sys.argv[2])
    num_edges = int(sys.argv[3])
    num_verts = int(sys.argv[4])
    num_cols = int(sys.argv[5])
    directed = int(sys.argv[6])
    run_test(ak_server, graph_loc, num_edges, num_verts, num_cols, directed)
    
    