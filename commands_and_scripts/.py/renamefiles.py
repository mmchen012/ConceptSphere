import os
import re
import shutil

def renameFiles(path):
  file_list = os.listdir(path)

  for file in file_list:
    if os.path.isfile(path + file):
      m = re.search('(.*) \(EVA...local\'s conflicted copy ....-..-..\)(.*)', file)

      if m != None:
        #print(path)
        #print(file)
        #print(m.group(1) + m.group(2))
        shutil.move(path + file, path + m.group(1) + m.group(2))

    else:
      renameFiles('%s%s/' %(path, file))

renameFiles('./')
