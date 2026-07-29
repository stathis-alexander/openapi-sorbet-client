    class Pet < T::Struct
      extend T::Sig
      include WireHelpers

      const :id, Integer
      const :name, String
      const :tag, T.nilable(String)
