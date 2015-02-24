git-up
======

What is it ?
------------

git-up is a tool for continuous delivery, specialized in web projects. Pipeline process is fully automated, and only current and great unix tools are used: ssh, rsync and git.

It's purpose is to deliver a git project to its staging or production servers, as fast as possible, because continuous delivery need fast tools.

It is able to deliver one git repository to only one server, however he was build to deliver multi git projects to many servers, for high-traffic projects that needs many servers to be synced in parallel.

The implementation can seem strange and heavy, but git-up was created to be simple, safe and really fast for developpers, and simple things often need complex background.

This project is used since years for +12 projects deployed to +20 servers. Each deployment is done in less than 10 seconds, including the rsync between your local git repo to the deployment server with a low bandwidth :)


How ?
-----

So you have a git repository which contains a full website, you add a commit and you want to deploy it in production platform. You also want that when you push this commit to "master" branch, it is deployed to your pre-production servers, and you want to deploy to your production servers via `git up prod` command.

1. simple push to master branch

        $ git push origin master

2. simple git alias to deploy to production servers

        $ git up prod

`git up` will fire a deploy process which is described bellow.


Flow
----

The deliver process is quite simple, and needs only tools that are already installed in your server.


        +----------------------------------------------------------------------------------------------------------------------+
        |                                                                                                                      |
        |       Locals                   +-----------------------------------------------------------+        DC / cloud       |
        |                                |                                                           |                         |
        |     +-------+                  |         Offices              +       Datacenters          |                         |
        |     |       |                  |                              |                            |                         |
        |     | Dev#1 +-------+          |                              |                            |                         |
        |     |       |       |          |   +-----------------+        |                            |       +-----------+     |
        |     +-------+       |          |   |                 |        |                            |       |           |     |
        |                     +- push -----> | gitolite/gitlab |        |                    +-------------> | server#A  |     |
        |                     |          |   |                 |        |                    |       |       |           |     |
        |                     |          |   +-------+---------+        |                    |       |       +-----------+     |
		|                     |          |           |                  |                    |       |                         | 
		|                     |          |       ADC hook               |                    |       |                         | 
        |                     |          |           |                  |                    | rsync |                         |
        |                     |          |           v                  |                    |       |       +-----------+     |
        |                     |          |   +-------+--------+         |       +------------+----+  |       |           |     |
        |     +-------+       |          |   |                |         |       |                 +--------> | server#B  |     |
        |     |       |       |          |   |                |    git-sync     |                 |  |       |           |     |
        |     | Dev#2 +-------+          |   | provisionning  +----  rsync ---> | deploy server   |  |       +-----------+     |
        |     |       |       |          |   |                |    over ssh     |                 |  |                         |
        |     +-------+       |          |   |                |         |       |                 +--------> +-----------+     |
        |              ssh    |          |   +----------------+         |       +------------+----+  |       |           |     |
        |     +-------+       |          |                              |                    |       |       | server#C  |     |
        |     |       |       |          |                              |                    |       |       |           |     |
        |     | Dev#n +-------+          |                              |                    |       |       +-----------+     |
        |     |       |                  |                              |                    | rsync |                         |
        |     +-------+                  |                              |                    |       |       +-----------+     |
        |                                |                              |                    |       |       |           |     |
        |                                |                              |                    +-------------> | server#...|     |
        |                                |                              |                            |       |           |     |
        |                                |                              +                            |       +-----------+     |
        |                                |                 it can be one server, or 2                |                         |
        |                                +-----------------------------------------------------------+                         |
        |                                                                                                                      |
        +----------------------------------------------------------------------------------------------------------------------+
                                                                                                                                

1. `git up` will first do some sanity checks, 
2. then, it will compare your commits to provisionning server which contains a clone of your git project
3. In some case, a diff or a list of changed files will be displayed
4. the provisionning clone will checkout your project to the git ref (commit, branch, tag, ...) you tell 
5. a SSH tunnel will be opened between the provisionning server and the deploy server
6. the project is rsynced to the deploy server, without the .git folder
7. the deploy server will call another script which will rsync in parallel to all your production servers





Why so many servers ?
---------------------

In short, for security and performance, and safer delivers.

The provisionning server can have many roles and can be your development server. It is the last which will have the .git folder, and his main goal is to maintain a mirror of your production or staging code. You can use it as a demo environment ! With him, many checks are done locally, in your LAN, it only use some disk space, no more than a clone of your git project.

It is also a security step. Thanks to him, developpers will not have access to your production infrastructure. A lock is created at this step, to disallow split-brain or split-things.

Finally, it's mandatory to have only one source to rsync to production servers, and to only have one deployment at a time.

The "deliver server" is one of your production server. It can be a spare or a job server, but he has to be near your production servers. If down, any other production server can take the role. A first sync to this server must be done, to do the parallel sync to all servers.



Installation
------------

### User side: install deployment tools

`curl -sS https://github.com/ezweb/git-up | sh -- --install-dir=~/.git-up`

It will setup `git up` alias, and download scripts to `~/.git-up` folder.


### Server side

We use [Ansible](http://www.ansible.com/) and you just have to add a role to your playbooks :
- `git-up-provision` : to configure the provisionning server
- `git-up-deployable` : for all your production servers

If you use another orchestration tool, there is not so much to do.

#### Prerequisites

Developpers than know git, and the ones who have to deliver needs to know terminal and ssh.

Ansible roles are available to help you setup provisionning and destination servers. They need a Debian server, but it's up to you to hack them for any other distribution, it's not a big deal, only few tools to have.

- ssh
- perl (python?)
- rsync


Usage
-----

- `git up <env> <commit-ish>` : default to env=preprod and commit-ish=origin/master

Since we can't trigger post-receive hook when nothing is pushed, we can re-deploy this way:
- `ssh <remote uri> up <env> <commit-ish>`
However, to do that we need [ADCs](http://gitolite.com/gitolite/g2/ADCs.html) which is a feature only proposed by
Gitolite. An [issue#213](https://github.com/gitlabhq/gitlab-shell/issues/213) is proposed on gitlab-shell.

Security
--------

SSH is used for all connections. 

Developpers or anyone who need to deliver must have there ssh keys authorized in the provisionning server. That's all you need to do, easy !


Tests
-----

The Vagrant is used to emulate an provisionning or a deploy server.


