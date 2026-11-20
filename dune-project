(lang dune 3.4)

(cram enable)

(generate_opam_files true)

(source
 (github Kakadu/crapper-ml))

(license LGPL-3.0-only)

(authors "Kakadu")

(maintainers "kakadu.hafanana@gmail.com")

(name crapper-ml)

(package
 (name crapper-ml)
 (version 0.1.0)
 (synopsis "Calculate CRAP metric")
 (depends
  (ocaml
   (or
    (and
     (>= 4.14.2)
     (< 5.0.0))
    (and
     (>= 5.3.0)
     (< 5.4.0))
    (and
     (>= 5.5.0)
     (< 5.6.0))))
  dune-build-info
  (bisect_ppx :with-dev-setup)
  (ocamlformat
   (and
    (= 0.27.0)
    :with-dev-setup))
  ;odig ; documentation flag remove for an experiment
  (odoc :with-doc)))
