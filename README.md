git-up
======


Table of Contents
-----------------

 * [What is it ?](#what-is-it-)
 * [How ?](#how-)
 * [Flow](#flow)
 * [Why so many servers ?](#why-so-many-servers-)
 * [Installation](#installation)
   * [User side: install deployment tools](#user-side-install-deployment-tools)
   * [Server side](#server-side)
     * [Prerequisites](#prerequisites)
 * [Usage](#usage)
 * [Security](#security)
 * [Tests](#tests)


What is it ?
------------

git-up is a tool for continuous delivery, specialized in web projects. Pipeline process is fully automated, and only current and great unix tools are used: ssh, rsync and git.

Its purpose is to deliver a git project to its staging or production servers, as fast as possible, because continuous delivery needs fast tools.

It is able to deliver one git repository to only one server, however it was built to deliver multi git projects to many servers, for high-traffic projects that need many servers to be synced in parallel.

The implementation can seem strange and heavy, but git-up was created to be simple, safe and really fast for developers, and simple things often need complex background.

This project is used in production since years for +12 projects and deployed to +20 servers. Each deployment is done in less than 10 seconds, including the rsync between your local git repo to the deployment server with a low bandwidth :)


How ?
-----

So you have a git repository that contains a full website, you add a commit and you want to deploy it to the production platform. You also want to deploy to your pre-production servers when you push this commit to "master" branch, and you want to deploy to your production servers via `git up prod` command.

1. simple push to master branch

        $ git push origin master

2. simple git alias to deploy to production servers

        $ git up prod

`git up` will fire a deploy process which is described below.


Flow
----

The delivery process is quite simple, it only needs tools that are already installed on your server.


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
        |     | Dev#2 +-------+          |   | provisioning   +----  rsync ---> | deploy server   |  |       +-----------+     |
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
2. Then, it will compare your commits to provisioning server which contains a clone of your git project
3. In some cases, a diff or a list of changed files will be displayed
4. The provisioning clone will checkout your project to the git ref (commit, branch, tag, ...) you specify 
5. An SSH tunnel will be opened between the provisioning server and the deployment server
6. The project is rsynced to the deployment server, without the .git folder
7. The deploy server will call another script which will rsync in parallel to all your production servers


Why so many servers ?
---------------------

In short, for security, performance, and safer deliveries.

The provisioning server can have many roles and can be your development server. It is the last that will have the .git folder, and its main goal is to maintain a mirror of your production or staging code. You can use it as a demo environment! Many checks are done locally with it, on your LAN, it only uses some disk space, not more than a clone of your git project.

It is also a security step. Thanks to it, developers will not have access to your production infrastructure. A lock is created at this step, to disallow split-brain or split-things.

Finally, it's mandatory to have only one source to rsync to production servers, and to only have one deployment at a time.

The "delivery server" is one of your production servers. It can be a spare or a job server, but it has to be close to your production servers. In case it's down, any other production server can take the role. A first sync to this server must be done, to do the parallel sync to all servers.


Installation
------------

### User side: install deployment tools

`curl -sSL https://raw.githubusercontent.com/mathroc/git-up/master/bin/setup | sh -s -- --no-alias`

or if you want to install it to another folder:

`curl -sSL https://raw.githubusercontent.com/mathroc/git-up/master/bin/setup | sh -s -- no-alias --install-dir ~/.git-up`

It will setup `git up` alias, and download scripts to your `~/.git-up` folder.


#### Configuration

`git up` will try to guess configuration, but sometimes you have to configure it.

If your deploy server is not your main git remote, like github.com, you can configure it this way:
```
$ git config --global up.host your_host.local
```


### Server side

We use [Ansible](http://www.ansible.com/) and you just have to add a role to your playbooks:
- `git-up-provision`: to configure the provisioning server
- `git-up-deployable`: for all your production servers

If you use another orchestration tool, there is not so much to do.

Include git-up-deployable this way :

```
-- in your playbook.yml
  - { role: git-up-deployable,
      deploy_hosts:
	  - 127.0.0.1
      - 192.168.0.0/16
      deploy_conf: [{
        name: "deployA",
        user: "userA",
        group: "userA",
        uid: 333,
        home: "/home/userA",
        folder: "/var/local/workA",
        hosts: "{{ deploy_hosts }}",
        },{
        name: "deployB",
        user: "userB",
        group: "userB",
        uid: 334,
        home: "/home/userB",
        folder: "/var/local/workB",
        hosts: "{{ deploy_hosts }}",
      }]
    }
```

Then, you'll need a role to assemble /etc/rsync.d configuration files to /etc/rsyncd.conf

#### Prerequisites

Developpers than know git, and the ones who have to deliver need to know terminal and ssh.

Ansible roles are available to help you setup your provisioning and destination servers. They need a Debian server, but it's up to you to hack them for any other distribution, it's not a big deal, only a few tools are needed.

- ssh
- perl
- rsync


#### gitolite specific

Login to your gitolite server and :
```
cd ~git
git clone https://github.com/ezweb/git-up.git

sed -r 's/^#? ?\$GL_ADC_PATH ?= (.+)/$GL_ADC_PATH = "git-up\/adc";/' .gitolite.rc 
# OR
vim .gitolite.rc # and change $GL_ADC_PATH to "git-up/adc"
```


Configuration
-------------

Default configuration is set in `conf.d/defaults.cfg` and can be overriden by your own config files in your own git repository.
You have to clone your git-up-config repository to `git-up/../git-up-config` folder on the gitolite/gitlab server.


Usage
-----

- `git up <env> <commit-ish>`: default to env=preprod and commit-ish=origin/master

Since we can't trigger post-receive hook when nothing is pushed, we can re-deploy this way:
- `ssh <remote uri> up <env> <commit-ish>`
However, to do that we need [ADCs](http://gitolite.com/gitolite/g2/ADCs.html) which is a feature only proposed by
Gitolite. An [issue#213](https://github.com/gitlabhq/gitlab-shell/issues/213) is proposed on gitlab-shell.


Security
--------

SSH is used for all connections. 

Developers or anyone that needs to deliver must have their ssh keys authorized in the provisioning server. That's all you need to do, easy!


Tests
-----

Vagrant is used to emulate a provisioning or deployment server.


Todo
----

* Handle big repositories: [nice blog article](http://blogs.atlassian.com/2014/05/handle-big-repositories-git/)

