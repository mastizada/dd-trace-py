import threading
import weakref

from ddtrace.internal import compat
from ddtrace.internal import nogevent

from . import _threading


try:
    import gevent.hub
    import gevent.thread
    from greenlet import getcurrent
    from greenlet import greenlet
    from greenlet import settrace
except ImportError:
    _gevent_tracer = None
else:

    class DDGreenletTracer(object):
        def __init__(self):
            # type: (...) -> None
            self.previous_trace_function = settrace(self)
            self.greenlets = weakref.WeakValueDictionary()
            self.active_greenlet = getcurrent()
            self._store_greenlet(self.active_greenlet)

        def _store_greenlet(
                self,
                greenlet,  # type: greenlet.greenlet
        ):
            # type: (...) -> None
            self.greenlets[gevent.thread.get_ident(greenlet)] = greenlet

        def __call__(self, event, args):
            if event in ('switch', 'throw'):
                # Do not trace gevent Hub: the Hub is a greenlet but we want to know the latest active greenlet *before*
                # the application yielded back to the Hub. There's no point showing the Hub most of the time to the
                # users as that does not give any information about user code.
                if not isinstance(args[1], gevent.hub.Hub):
                    self.active_greenlet = args[1]
                    self._store_greenlet(args[1])

            if self.previous_trace_function is not None:
                self.previous_trace_function(event, args)

    # NOTE: bold assumption: this module is always imported by the MainThread.
    # A GreenletTracer is local to the thread instantiating it and we assume this is run by the MainThread.
    _gevent_tracer = DDGreenletTracer()


cpdef get_task(thread_id):
    """Return the task id and name for a thread."""
    # gevent greenlet support:
    # we only support tracing tasks in the greenlets are run in the MainThread.
    if thread_id == nogevent.main_thread_id and _gevent_tracer is not None:
        task_id = gevent.thread.get_ident(_gevent_tracer.active_greenlet)
        # Greenlets might be started as Thread in gevent
        task_name = _threading.get_thread_name(task_id)
        frame = _gevent_tracer.active_greenlet.gr_frame
    else:
        task_id = None
        task_name = None
        frame = None

    return task_id, task_name, frame


cpdef list_tasks(thread_id):
    # type: (...) -> typing.List[typing.Tuple[int, str, types.FrameType]]
    """Return the list of running tasks.

    This is computed for gevent by taking the list of existing threading.Thread object and removing if any real OS
    thread that might be running.

    :return: [(task_id, task_name, task_frame), ...]"""
    # We consider all Thread objects to be greenlet
    # This should be true as nobody could use a half-monkey-patched gevent
    if thread_id == nogevent.main_thread_id and _gevent_tracer is not None:
        return [
            (greenlet_id,
             _threading.get_thread_name(greenlet_id),
             greenlet.gr_frame)
            for greenlet_id, greenlet in compat.iteritems(_gevent_tracer.greenlets)
            if not greenlet.dead
        ]

    return []
