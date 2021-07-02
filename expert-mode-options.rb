Expert-Mode Options
inherit_socket: true: disable safety check that prevents a forked child from sharing a socket with its parent; this is potentially useful in order to mitigate connection churn when:

many short-lived forked children of one process need to talk to redis, AND
your own code prevents the parent process from using the redis connection while a child is alive
Improper use of inherit_socket will result in corrupted and/or incorrect responses.
