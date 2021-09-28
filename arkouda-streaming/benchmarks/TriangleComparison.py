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
    Graph = ak.graph_file_read(num_edges,num_vertices,num_cols, directed, graph_location)
    print("directed graph  ={}".format(Graph.directed))
    print("number of vertices=", int(Graph.n_vertices))
    print("number of edges=", int(Graph.n_edges))
    print("weighted graph  ={}".format(Graph.weighted))
    '''
    for i in range(3020,3056) :
         print(i,"=<",Graph.src[i]," -- ", Graph.dst[i],">")
    print("vertex, neighbour, start")
    for i in range(int(Graph.n_vertices)):
         print("<",i,"--", Graph.neighbour[i],"--", Graph.start_i[i], ">")
    print("source of edges   ={}".format(Graph.src))
    print("dest of edges     ={}".format(Graph.dst))
    print("start     ={}".format(Graph.start_i))
    print("neighbour ={}".format(Graph.neighbour))
    print("source of edges R  ={}".format(Graph.srcR))
    print("dest of edges R    ={}".format(Graph.dstR))
    print("start R       ={}".format(Graph.start_iR))
    print("neighbour R   ={}".format(Graph.neighbourR))
    print("neighbour size={}".format(Graph.neighbour.size))
    print("from src to dst")
    '''

    testval2 = ak.pdarraycreation.graph_triangle_edge(Graph,4)
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
    
    
'''
python TriangleComparison.py  tcp://node678:5555 /home/z/zd4/ArkoudaExtension/arkouda/delaunay_n10.gr 3056 1024 2 0
python TriangleComparison.py  tcp://node678:5555 /home/z/zd4/ArkoudaExtension/arkouda/email-Enron.gr 367662 36692  2 0
python TriangleComparison.py  tcp://node678:5555 /home/z/zd4/ArkoudaExtension/arkouda/100-1.gr 41 10  2 0
'''
