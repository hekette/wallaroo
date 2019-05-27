# Copyright 2019 The Wallaroo Authors.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#  implied. See the License for the specific language governing
#  permissions and limitations under the License.


import datetime
import logging
import os
import time


from integration.cluster import Cluster

from integration.logger import (add_in_memory_log_stream,
                                set_logging)

from integration.end_points import (Reader,
                                    Sender)

from integration.external import save_logs_to_file

set_logging(name="conformance")


class TestHarnessException(Exception):
    pass


class Application:
    name = 'BaseApplication'
    command = None
    config = {}
    host = '127.0.0.1'
    workers = 1
    sources = ['Detector']
    sinks = 1
    sink_mode = 'framed'
    split_streams = True
    log_rotation = False

    ##########
    # In/Out #
    ##########
    def send_tcp(self, gen, src_name=None, block=True):
        logging.debug("send_tcp")
        sender = self.add_tcp_sender(gen, src_name)
        if block:
            sender.join()
            if sender.error:
                raise sender.error
        logging.debug("end of send_tcp")
        return sender

    def add_tcp_sender(self, gen, src_name=None, start=True):
        if not self.cluster:
            raise TestHarnessException("Can't add a sender before creating "
                    "a cluster!")
        if src_name is None:
            src_name = self.sources[0]
        sender = Sender(address = self.cluster.source_addrs[0][src_name],
                        reader = Reader(gen))
        self.cluster.add_sender(sender, start)
        return sender

    def sink_await(self, values, timeout=30, func=lambda x: x, sink=-1):
        if not self.cluster:
            raise TestHarnessException("Can't sink_await before creating "
                    "a cluster!")
        self.cluster.sink_await(values, timeout, func, sink)

    # TODO
    #def sink_expect(self, *args, **kwargs):

    def collect(self, sink=None):
        if not self.cluster:
            raise TestHarnessException("Can't collect before creating "
                    "a cluster!")
        if sink:
            return self.cluster.sinks[sink].data
        return self.cluster.sinks[0].data


    ###########################
    ## Context Manager parst ##
    ###########################
    def __init__(self):
        self.log_stream = add_in_memory_log_stream(level=logging.DEBUG)
        current_test = (os.environ.get('PYTEST_CURRENT_TEST')
                        .rsplit(' (call)')[0])
        cwd = os.getcwd()
        trunc_head = cwd.find('/wallaroo/') + len('/wallaroo/')
        t0 = datetime.datetime.now()
        self.base_dir = os.path.join('/tmp/wallaroo_test_errors',
            cwd[trunc_head:],
            current_test,
            t0.strftime('%Y%m%d_%H%M%S'))
        self.persistent_data = {}

    def __enter__(self):
        if self.command is None:
            raise ValueError("command cannot be None. Please initialize {}"
                    " with a valid command argument!".format(
                        self))
        command = "{} {}".format(self.command,
            " ".join(("--{} {}".format(k, v)
                      for k, v in self.config.items())))
        self.cluster = Cluster(command = command,
                     host = self.host,
                     sources = self.sources,
                     workers = self.workers,
                     split_streams = self.split_streams,
                     log_rotation = self.log_rotation,
                     persistent_data = self.persistent_data)
        self.cluster.__enter__()
        time.sleep(0.1)
        return self

    def __exit__(self, _type, _value, _traceback):
        logging.debug("{}.__exit__({}, {}, {})".format(self, _type, _value,
            _traceback))
        self.cluster.__exit__(None, None, None) #_type, _value, _traceback)
        if _type or _value or _traceback:
            save_logs_to_file(self.base_dir,
                              self.log_stream,
                              self.persistent_data)
