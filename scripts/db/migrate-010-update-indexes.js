db.users.ensureIndex({full_name: 1}, {background: true})
db.users.update({'full_name': {$exists : false}, 'username': {$exists: true}}, {$set: {'full_name': ''}})
